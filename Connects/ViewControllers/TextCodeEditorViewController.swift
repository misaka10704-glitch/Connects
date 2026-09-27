import UIKit
import WebKit

/// Study-mode code / plain-text editor with syntax highlighting.
final class TextCodeEditorViewController: UIViewController, UITextViewDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate, WKScriptMessageHandler {
    private let topBar = UIView()
    private let topBarSeparator = UIView()
    private let sidebarButton = UIButton(type: .system)
    private let modeButton = UIButton(type: .system)
    private let buildButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let appearanceButton = UIButton(type: .system)
    private let rotateButton = UIButton(type: .system)
    private var rotateButtonWidthConstraint: NSLayoutConstraint!
    private var fileTitleCenterXBar: NSLayoutConstraint!
    private var fileTitleCenterXSlot: NSLayoutConstraint!
    private let titleSlotGuide = UILayoutGuide()
    private let fileTitleButton = UIButton(type: .system)
    private let pinchScaleHost = UIView()
    private let gutterView = UIView()
    private let gutterSeparator = UIView()
    /// Drawn from `textView.layoutManager` fragments so wrap/pinch/scroll stay aligned.
    private let lineNumberView = CodeLineNumberGutterView()
    private let textView = StudyAskTextView(fullLineBackgrounds: true)
    private let spinner = UIActivityIndicatorView(style: .medium)
    /// Markdown preview only (`language == .markdown`). Transitional WK shell — see markdown-render-engine rule.
    private var previewWebView: WKWebView!
    private var previewShellLoaded = false
    private var pendingPreviewMarkdown: String?
    private let previewAssetHandler = MarkdownPreviewAssetSchemeHandler()
    /// Markdown edit ↔ preview: pin the source location that was at the viewport top.
    private var pendingModeScrollAnchor: ModeScrollAnchor?
    /// Restore scroll after theme rebuilds the Markdown preview WK shell.
    private var pendingThemeViewportProgress: StudyProgress?

    /// Avoid re-entrant preview→edit while resolving the top-of-viewport snippet via JS.
    private var isResolvingPreviewScrollAnchor = false

    private struct ModeScrollAnchor {
        /// UTF-16 index in source to place at the visual top.
        var sourceUTF16Index: Int
        /// Visible text near that spot (helps find the matching rendered node).
        var snippet: String
    }

    private var currentDocumentID: String?
    private var language: StudyTextLanguage = .plain
    private var loadGeneration: UInt = 0
    private var sidebarButtonWidthConstraint: NSLayoutConstraint!
    private var buildButtonWidthConstraint: NSLayoutConstraint!
    private var gutterWidthConstraint: NSLayoutConstraint!
    private var isEditMode = false
    private var isDirty = false
    private var isPlanDocument = false
    /// Reading sub-state. `diff` = hunk UI; `diffPreview` = all-kept plain preview (still in Diff session).
    private enum ReadSurface { case plain, diff, diffPreview }
    private var readSurface: ReadSurface = .plain
    private var tabCompletionEnabled: Bool = {
        guard CodeEditorFeatureFlags.tabCompletionEnabled else { return false }
        if UserDefaults.standard.object(forKey: "connects.codeEditor.tabCompletion") == nil { return true }
        return UserDefaults.standard.bool(forKey: "connects.codeEditor.tabCompletion")
    }()
    private var ghostSuggestion: String?
    private var tabCompleteWorkItem: DispatchWorkItem?
    private var tabCompleteGeneration: UInt = 0
    private let tabToggleButton = UIButton(type: .system)
    private var tabToggleWidthConstraint: NSLayoutConstraint!
    /// Caret-trailing Tab accept chip (not a bottom dock).
    private let tabSuggestChip = UIView()
    private let tabSuggestLabel = UILabel()
    private let tabConfirmButton = UIButton(type: .system)
    private let tabDismissButton = UIButton(type: .system)
    /// Legacy floating nav container — kept hidden; ▲ n/N ▼ sit on every hunk Undo/Keep bar.
    private let diffHunkBar = UIView()
    private let diffNavLabel = UILabel()
    private let diffPrevButton = UIButton(type: .system)
    private let diffNextButton = UIButton(type: .system)
    /// Per-pending-hunk Undo/Keep chips — subviews of `textView` in **content** coords
    /// so UIScrollView scrolls them with the hunk (no per-frame remapping).
    private var diffPerHunkBars: [UIView] = []
    private var textBottomToView: NSLayoutConstraint!
    private var gutterBottomToView: NSLayoutConstraint!
    private var gutterSepBottomToView: NSLayoutConstraint!
    private var diffBeforeSnapshot: String?
    private var diffAfterSnapshot: String?
    private var diffSegments: [CodeDiffSegment] = []
    private var diffHunkRanges: [Int: NSRange] = [:]
    /// Document-space Y (text-container + inset) for pending hunks — scroll converts via contentOffset.
    private var diffHunkDocY: [Int: (minY: CGFloat, maxY: CGFloat)] = [:]
    private var lastDiffSyncOffsetY: CGFloat = -10_000
    private var lastDiffSyncAt: CFTimeInterval = 0
    private var diffChromeZOrdered = false
    private var diffFocusHighlightWork: DispatchWorkItem?
    private var diffCurrentPendingIndex = 0
    /// Bumps when a new Diff session is presented / cancelled (async compute guard).
    private var diffPresentGeneration: UInt = 0
    /// Extra bottom inset while a soft keyboard covers the reader (portrait Study).
    private var keyboardBottomInset: CGFloat = 0
    private var highlightWorkItem: DispatchWorkItem?
    /// Ask 选区：语法高亮之上的持久背景，不依赖系统选区（用户可先读后开 AI）。
    private var askPinnedRange: NSRange?
    private var saveWorkItem: DispatchWorkItem?
    private var isApplyingHighlight = false
    private var readerSurfaceActive = true
    private var pendingViewportProgress: StudyProgress?
    /// Character at the visual top — wrap/rotation must restore this, not a raw Y offset.
    private var pendingViewportUTF16: Int?
    private var wrapRestoreGeneration: UInt = 0
    private var conversationIDForDirty: String?

    // MARK: - AI edit / Tab / inline diff (CodeEditorAIBridge)
    // Implemented on this VC; coordinator drives Diff + Keep/Reject.

    private static let fontSizeDefaultsKey = "connects.codeEditor.fontSize"
    private static let markdownPreviewFontDefaultsKey = "connects.markdownPreview.fontSize"
    private static let minFontPointSize: CGFloat = 9
    private static let minMarkdownPreviewFont: CGFloat = 11
    /// iPhone 26 / iPad 32 — shared ceiling for editor + Markdown preview pinch.
    private static var deviceMaxFontPointSize: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 32 : 26
    }
    private static var maxFontPointSize: CGFloat { deviceMaxFontPointSize }
    private static var maxMarkdownPreviewFont: CGFloat { deviceMaxFontPointSize }
    private var fontPointSize: CGFloat = {
        let max = TextCodeEditorViewController.deviceMaxFontPointSize
        let stored = UserDefaults.standard.double(forKey: TextCodeEditorViewController.fontSizeDefaultsKey)
        if stored >= 9, stored <= Double(max) { return CGFloat(stored) }
        if stored > Double(max) { return max }
        return CodeSyntaxHighlighter.defaultPointSize
    }()
    private var markdownPreviewFontSize: CGFloat = {
        let max = TextCodeEditorViewController.deviceMaxFontPointSize
        let stored = UserDefaults.standard.double(forKey: TextCodeEditorViewController.markdownPreviewFontDefaultsKey)
        if stored >= 11, stored <= Double(max) { return CGFloat(stored) }
        if stored > Double(max) { return max }
        return 17
    }()
    private var pinchBaseFontSize: CGFloat = CodeSyntaxHighlighter.defaultPointSize
    private var pinchTargetsPreview = false
    private var pinchAnchorUTF16: Int = 0
    private var pinchScrollOffset: CGPoint = .zero
    private var pinchAttributedSnapshot: NSAttributedString?
    private var isLivePinching = false

    var onPageChanged: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onFileTitleTapped: ((UIView) -> Void)?
    var onContentEdited: (() -> Void)?
    var onAskSelection: ((String) -> Void)?
    /// Plan markdown: run Agent Build from the text/markdown chrome.
    var onBuildPlan: (() -> Void)?
    var onToggleReaderLandscape: (() -> Void)?

    private var lastWrapLayoutWidth: CGFloat = 0

    private var showsMarkdownPreview: Bool {
        language == .markdown && !isEditMode && readSurface == .plain
    }

    var onDiffDecision: ((Bool) -> Void)?
    /// Called with final file text when all hunks are resolved; `nil` = cancel / all undone to before.
    var onDiffFinished: ((String?) -> Void)?
    /// `(active, pendingHunkCount)` — drives the chat InputBar review banner.
    var onDiffSessionChange: ((Bool, Int) -> Void)?
    weak var completionProvider: CodeEditorCompletionProviding?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DSTheme.reader.background
        StudyAskMenu.installIfNeeded()

        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        topBarSeparator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBarSeparator)

        sidebarButton.translatesAutoresizingMaskIntoConstraints = false
        sidebarButton.addTarget(self, action: #selector(sidebarTapped), for: .touchUpInside)
        sidebarButton.accessibilityLabel = "打开侧栏"
        topBar.addSubview(sidebarButton)
        updateSidebarToggle(collapsed: true)
        sidebarButtonWidthConstraint = sidebarButton.widthAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget)

        modeButton.translatesAutoresizingMaskIntoConstraints = false
        modeButton.setImage(ActionIconFactory.image(.editMode, pointSize: ActionIconFactory.chromeGlyph), for: .normal)
        modeButton.imageView?.contentMode = .scaleAspectFit
        modeButton.addTarget(self, action: #selector(modeTapped), for: .touchUpInside)
        modeButton.accessibilityLabel = "切换到编辑模式"
        topBar.addSubview(modeButton)

        buildButton.translatesAutoresizingMaskIntoConstraints = false
        buildButton.setTitle("Build", for: .normal)
        buildButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        buildButton.setTitleColor(DSTheme.reader.accent, for: .normal)
        buildButton.setTitleColor(DSTheme.reader.accent.withAlphaComponent(0.55), for: .highlighted)
        buildButton.addTarget(self, action: #selector(buildTapped), for: .touchUpInside)
        buildButton.accessibilityLabel = "按计划 Build"
        buildButton.isHidden = true
        topBar.addSubview(buildButton)
        buildButtonWidthConstraint = buildButton.widthAnchor.constraint(equalToConstant: 0)

        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.setImage(ActionIconFactory.image(.save, pointSize: ActionIconFactory.chromeGlyph), for: .normal)
        saveButton.imageView?.contentMode = .scaleAspectFit
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        saveButton.accessibilityLabel = "保存"
        topBar.addSubview(saveButton)

        appearanceButton.translatesAutoresizingMaskIntoConstraints = false
        appearanceButton.addTarget(self, action: #selector(appearanceTapped), for: .touchUpInside)
        topBar.addSubview(appearanceButton)
        updateAppearanceButton()

        rotateButton.translatesAutoresizingMaskIntoConstraints = false
        rotateButton.setImage(ActionIconFactory.image(.rotate, pointSize: ActionIconFactory.chromeGlyph), for: .normal)
        rotateButton.addTarget(self, action: #selector(rotateTapped), for: .touchUpInside)
        topBar.addSubview(rotateButton)
        let phoneRotate = ConnectsPhoneReaderLandscape.isPhone
        rotateButton.isHidden = !phoneRotate
        rotateButtonWidthConstraint = rotateButton.widthAnchor.constraint(
            equalToConstant: phoneRotate ? ActionIconFactory.hitTarget : 0
        )
        updateRotateButtonAppearance()

        tabToggleButton.translatesAutoresizingMaskIntoConstraints = false
        tabToggleButton.setTitle("Tab", for: .normal)
        tabToggleButton.titleLabel?.font = UIFont.systemFont(ofSize: 11, weight: .bold)
        tabToggleButton.addTarget(self, action: #selector(tabToggleTapped), for: .touchUpInside)
        tabToggleButton.accessibilityLabel = "Tab 补全"
        tabToggleButton.accessibilityHint = "关闭后编辑时不再出现灰字建议"
        tabToggleWidthConstraint = tabToggleButton.widthAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget)
        topBar.addSubview(tabToggleButton)
        refreshTabToggleChrome()

        fileTitleButton.translatesAutoresizingMaskIntoConstraints = false
        fileTitleButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        fileTitleButton.titleLabel?.lineBreakMode = .byTruncatingMiddle
        fileTitleButton.titleLabel?.textAlignment = .center
        fileTitleButton.contentHorizontalAlignment = .center
        fileTitleButton.setTitleColor(DSTheme.reader.textPrimary, for: .normal)
        fileTitleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fileTitleButton.addTarget(self, action: #selector(fileTitleTapped), for: .touchUpInside)
        fileTitleButton.accessibilityLabel = "切换文件"
        topBar.addSubview(fileTitleButton)
        // Keep mode / Build / save / Tab above the title control.
        topBar.bringSubviewToFront(tabToggleButton)
        topBar.bringSubviewToFront(modeButton)
        topBar.bringSubviewToFront(buildButton)
        topBar.bringSubviewToFront(saveButton)
        topBar.bringSubviewToFront(appearanceButton)
        topBar.bringSubviewToFront(rotateButton)

        pinchScaleHost.translatesAutoresizingMaskIntoConstraints = false
        pinchScaleHost.clipsToBounds = true
        pinchScaleHost.backgroundColor = DSTheme.reader.background
        view.addSubview(pinchScaleHost)

        gutterView.translatesAutoresizingMaskIntoConstraints = false
        gutterView.clipsToBounds = true
        pinchScaleHost.addSubview(gutterView)

        lineNumberView.translatesAutoresizingMaskIntoConstraints = false
        lineNumberView.sourceTextView = textView
        lineNumberView.fontSize = fontPointSize
        gutterView.addSubview(lineNumberView)

        gutterSeparator.translatesAutoresizingMaskIntoConstraints = false
        pinchScaleHost.addSubview(gutterSeparator)

        gutterWidthConstraint = gutterView.widthAnchor.constraint(equalToConstant: 44)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.delegate = self
        textView.backgroundColor = DSTheme.reader.background
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 10)
        textView.textContainer.lineFragmentPadding = 0
        // Soft-wrap to the editor width so long lines are not clipped on the right.
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.lineBreakMode = .byCharWrapping
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardDismissMode = .interactive
        textView.alwaysBounceVertical = true
        textView.alwaysBounceHorizontal = false
        textView.showsHorizontalScrollIndicator = false
        textView.typingAttributes = CodeSyntaxHighlighter.typingAttributes(fontSize: fontPointSize)
        textView.onAskSelection = { [weak self] text in
            self?.onAskSelection?(text)
        }
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handleFontPinch(_:)))
        pinch.delegate = self
        textView.addGestureRecognizer(pinch)
        if #available(iOS 11.0, *) {
            textView.contentInsetAdjustmentBehavior = .never
        }
        textView.editorKeyCommandsProvider = { [weak self] in
            self?.keyCommands
        }
        pinchScaleHost.addSubview(textView)

        // Caret-trailing Tab accept chip (frame-based; subviews use Auto Layout).
        tabSuggestChip.translatesAutoresizingMaskIntoConstraints = true
        tabSuggestChip.isHidden = true
        tabSuggestChip.backgroundColor = DSTheme.reader.surface
        tabSuggestChip.layer.cornerRadius = 10
        tabSuggestChip.layer.borderWidth = 1 / UIScreen.main.scale
        tabSuggestChip.layer.borderColor = DSTheme.reader.border.cgColor
        tabSuggestChip.clipsToBounds = true
        view.addSubview(tabSuggestChip)

        tabSuggestLabel.translatesAutoresizingMaskIntoConstraints = false
        tabSuggestLabel.font = CodeSyntaxHighlighter.font(size: fontPointSize)
        tabSuggestLabel.textColor = DSTheme.reader.textTertiary
        tabSuggestLabel.numberOfLines = 2
        tabSuggestLabel.lineBreakMode = .byTruncatingTail
        tabSuggestChip.addSubview(tabSuggestLabel)

        tabConfirmButton.translatesAutoresizingMaskIntoConstraints = false
        tabConfirmButton.setTitle("Accept", for: .normal)
        tabConfirmButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        tabConfirmButton.addTarget(self, action: #selector(acceptGhostTapped), for: .touchUpInside)
        tabSuggestChip.addSubview(tabConfirmButton)

        tabDismissButton.translatesAutoresizingMaskIntoConstraints = false
        tabDismissButton.setTitle("×", for: .normal)
        tabDismissButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        tabDismissButton.addTarget(self, action: #selector(dismissGhostTapped), for: .touchUpInside)
        tabSuggestChip.addSubview(tabDismissButton)

        NSLayoutConstraint.activate([
            tabSuggestLabel.leadingAnchor.constraint(equalTo: tabSuggestChip.leadingAnchor, constant: 10),
            tabSuggestLabel.topAnchor.constraint(equalTo: tabSuggestChip.topAnchor, constant: 8),
            tabSuggestLabel.bottomAnchor.constraint(equalTo: tabSuggestChip.bottomAnchor, constant: -8),
            tabConfirmButton.leadingAnchor.constraint(equalTo: tabSuggestLabel.trailingAnchor, constant: 8),
            tabConfirmButton.centerYAnchor.constraint(equalTo: tabSuggestChip.centerYAnchor),
            tabConfirmButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
            tabDismissButton.leadingAnchor.constraint(equalTo: tabConfirmButton.trailingAnchor, constant: 4),
            tabDismissButton.trailingAnchor.constraint(equalTo: tabSuggestChip.trailingAnchor, constant: -6),
            tabDismissButton.centerYAnchor.constraint(equalTo: tabSuggestChip.centerYAnchor),
            tabDismissButton.widthAnchor.constraint(equalToConstant: 28)
        ])

        // Floating top-right nav retired — ▲ n/N ▼ sit on the focused hunk's Undo/Keep bar.
        diffHunkBar.isHidden = true
        diffHunkBar.isUserInteractionEnabled = false
        diffPrevButton.addTarget(self, action: #selector(diffPrevHunk), for: .touchUpInside)
        diffNextButton.addTarget(self, action: #selector(diffNextHunk), for: .touchUpInside)

        let config = ConnectsWebKit.makeConfiguration()
        config.setURLSchemeHandler(previewAssetHandler, forURLScheme: MarkdownPreviewAssetIndex.scheme)
        config.userContentController.add(WeakScriptMessageHandler(delegate: self), name: "studyAsset")
        previewWebView = WKWebView(frame: .zero, configuration: config)
        previewWebView.translatesAutoresizingMaskIntoConstraints = false
        ConnectsWebKit.applyReadingSurfaceTuning(previewWebView, background: DSTheme.reader.background)
        previewWebView.scrollView.isScrollEnabled = true
        previewWebView.scrollView.alwaysBounceHorizontal = false
        previewWebView.scrollView.showsHorizontalScrollIndicator = false
        previewWebView.scrollView.isDirectionalLockEnabled = true
        previewWebView.scrollView.delegate = self
        previewWebView.isHidden = true
        previewWebView.navigationDelegate = self
        let previewPinch = UIPinchGestureRecognizer(target: self, action: #selector(handleFontPinch(_:)))
        previewPinch.delegate = self
        previewWebView.addGestureRecognizer(previewPinch)
        view.addSubview(previewWebView)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),

            sidebarButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 4),
            sidebarButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            sidebarButtonWidthConstraint,
            sidebarButton.heightAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),

            // Visually centered in the remaining slot (portrait) / bar (landscape).
            fileTitleButton.topAnchor.constraint(equalTo: topBar.topAnchor),
            fileTitleButton.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            fileTitleButton.leadingAnchor.constraint(greaterThanOrEqualTo: sidebarButton.trailingAnchor, constant: 4),
            fileTitleButton.trailingAnchor.constraint(lessThanOrEqualTo: rotateButton.leadingAnchor, constant: -4),

            // Far-right chrome: [rotate?][Tab][mode][Build?][appearance][save]
            saveButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -4),
            saveButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            saveButton.widthAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),
            saveButton.heightAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),

            appearanceButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -2),
            appearanceButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            appearanceButton.widthAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),
            appearanceButton.heightAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),

            buildButton.trailingAnchor.constraint(equalTo: appearanceButton.leadingAnchor, constant: -2),
            buildButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            buildButton.heightAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),
            buildButtonWidthConstraint,

            modeButton.trailingAnchor.constraint(equalTo: buildButton.leadingAnchor, constant: -2),
            modeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            modeButton.widthAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),
            modeButton.heightAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),

            tabToggleButton.trailingAnchor.constraint(equalTo: modeButton.leadingAnchor, constant: -2),
            tabToggleButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            tabToggleWidthConstraint,
            tabToggleButton.heightAnchor.constraint(equalToConstant: 32),

            rotateButton.trailingAnchor.constraint(equalTo: tabToggleButton.leadingAnchor, constant: -2),
            rotateButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            rotateButtonWidthConstraint,
            rotateButton.heightAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),

            topBarSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBarSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBarSeparator.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            topBarSeparator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            pinchScaleHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pinchScaleHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pinchScaleHost.topAnchor.constraint(equalTo: topBarSeparator.bottomAnchor),
            pinchScaleHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            gutterView.leadingAnchor.constraint(equalTo: pinchScaleHost.leadingAnchor),
            gutterView.topAnchor.constraint(equalTo: pinchScaleHost.topAnchor),
            gutterWidthConstraint,

            lineNumberView.leadingAnchor.constraint(equalTo: gutterView.leadingAnchor),
            lineNumberView.trailingAnchor.constraint(equalTo: gutterView.trailingAnchor),
            lineNumberView.topAnchor.constraint(equalTo: gutterView.topAnchor),
            lineNumberView.bottomAnchor.constraint(equalTo: gutterView.bottomAnchor),

            gutterSeparator.leadingAnchor.constraint(equalTo: gutterView.trailingAnchor, constant: 6),
            gutterSeparator.topAnchor.constraint(equalTo: pinchScaleHost.topAnchor),
            gutterSeparator.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            textView.leadingAnchor.constraint(equalTo: gutterSeparator.trailingAnchor, constant: 10),
            textView.trailingAnchor.constraint(equalTo: pinchScaleHost.trailingAnchor),
            textView.topAnchor.constraint(equalTo: pinchScaleHost.topAnchor),

            previewWebView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewWebView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewWebView.topAnchor.constraint(equalTo: topBarSeparator.bottomAnchor),
            previewWebView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        textBottomToView = textView.bottomAnchor.constraint(equalTo: pinchScaleHost.bottomAnchor)
        gutterBottomToView = gutterView.bottomAnchor.constraint(equalTo: pinchScaleHost.bottomAnchor)
        gutterSepBottomToView = gutterSeparator.bottomAnchor.constraint(equalTo: pinchScaleHost.bottomAnchor)
        textBottomToView.isActive = true
        gutterBottomToView.isActive = true
        gutterSepBottomToView.isActive = true

        topBar.addLayoutGuide(titleSlotGuide)
        NSLayoutConstraint.activate([
            titleSlotGuide.leadingAnchor.constraint(equalTo: sidebarButton.trailingAnchor, constant: 4),
            titleSlotGuide.trailingAnchor.constraint(equalTo: rotateButton.leadingAnchor, constant: -4),
            titleSlotGuide.topAnchor.constraint(equalTo: topBar.topAnchor),
            titleSlotGuide.bottomAnchor.constraint(equalTo: topBar.bottomAnchor)
        ])
        fileTitleCenterXBar = fileTitleButton.centerXAnchor.constraint(equalTo: topBar.centerXAnchor)
        fileTitleCenterXSlot = fileTitleButton.centerXAnchor.constraint(equalTo: titleSlotGuide.centerXAnchor)
        syncFileTitlePlacement()

        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .readerThemeDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(phoneReaderLandscapeDidChange),
            name: .connectsPhoneReaderLandscapeDidChange,
            object: nil
        )
        applyChromeColors()
        // Defaults already match read mode; avoid applyEditMode during load (view has no window yet).
        isEditMode = false
        textView.isEditable = false
        textView.isSelectable = true
        refreshModeChrome()
        updateProgressLabel()
        syncSurfaceVisibility()
        liftTopChrome()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        liftTopChrome()
        lastWrapLayoutWidth = textView.bounds.width
        syncLineNumberOffset()
        if readSurface == .diff {
            layoutPerHunkActionBarsInContent()
            placeDiffNavChrome()
        }
    }

    /// Keep the 40pt chrome strip above text / preview / chips so mode & title stay tappable.
    private func liftTopChrome() {
        view.bringSubviewToFront(topBar)
        view.bringSubviewToFront(topBarSeparator)
        topBar.bringSubviewToFront(tabToggleButton)
        topBar.bringSubviewToFront(modeButton)
        topBar.bringSubviewToFront(saveButton)
        topBar.bringSubviewToFront(rotateButton)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func bindConversationID(_ id: String?) {
        conversationIDForDirty = id
    }

    func isLoaded(documentID: String) -> Bool {
        currentDocumentID == documentID
    }

    func setReaderSurfaceActive(_ active: Bool) {
        readerSurfaceActive = active
    }

    func updateSidebarToggle(collapsed: Bool) {
        let kind: ActionIconFactory.Kind = collapsed ? .sidebar : .sidebarOpen
        sidebarButton.setImage(ActionIconFactory.image(kind, pointSize: ActionIconFactory.chromeGlyph), for: .normal)
        sidebarButton.tintColor = DSTheme.reader.textSecondary
        sidebarButton.accessibilityLabel = collapsed ? "打开侧栏" : "关闭侧栏"
    }

    func setSidebarButtonHidden(_ hidden: Bool, animated: Bool = false) {
        let apply = {
            self.sidebarButton.alpha = hidden ? 0 : 1
            self.sidebarButton.isUserInteractionEnabled = !hidden
            // Keep width so file title layout stays stable while shell owns the floating key.
            self.sidebarButtonWidthConstraint.constant = 40
            self.sidebarButton.isHidden = false
        }
        if animated {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState], animations: apply)
        } else {
            apply()
        }
    }

    func sidebarButtonAnchorFrame(in target: UIView) -> CGRect {
        guard let bar = sidebarButton.superview else { return .zero }
        bar.layoutIfNeeded()
        // Pre-layout / cold start: zero-height bar makes y = -hitTarget/2 → floats above the screen.
        guard bar.bounds.height > 1, bar.window != nil else { return .zero }
        let y = (bar.bounds.height - ActionIconFactory.hitTarget) / 2
        return bar.convert(CGRect(x: 4, y: y, width: ActionIconFactory.hitTarget, height: ActionIconFactory.hitTarget), to: target)
    }

    func load(documentID: String, completion: @escaping (Bool) -> Void) {
        // Switching documents mid-Diff used to leave readSurface=.diff while
        // replacing text (or no-op after the highlight guard) — mode toggle stuck.
        cancelDiffReviewForExternalMutation()
        loadGeneration &+= 1
        let gen = loadGeneration
        currentDocumentID = documentID
        spinner.startAnimating()
        DispatchQueue.global(qos: .userInitiated).async {
            let text = StudyDocumentStore.shared.textContent(for: documentID) ?? ""
            DispatchQueue.main.async {
                guard self.loadGeneration == gen else { return }
                let doc = StudyDocumentStore.shared.document(id: documentID)
                var lang = doc?.textLanguage ?? .plain
                // Legacy StudyDocumentKind.markdown (or missing language) → Markdown preview/edit.
                let path = doc?.displayPath ?? doc?.localRelativePath ?? ""
                let pathExt = (path as NSString).pathExtension
                if doc?.kind == .markdown || StudyTextLanguage.infer(fromExtension: pathExt) == .markdown {
                    lang = .markdown
                }
                self.language = lang
                self.isDirty = false
                self.isPlanDocument = (lang == .markdown) && StudyPlanDocument.parse(text).isPlan
                self.applyHighlightedText(text)
                self.updateLineNumbers(force: true)
                self.syncLineNumberOffset()
                self.updateProgressLabel()
                self.syncSurfaceVisibility()
                self.refreshModeChrome()
                if self.showsMarkdownPreview {
                    self.refreshMarkdownPreview(text: text)
                }
                self.spinner.stopAnimating()
                completion(true)
            }
        }
    }

    func clearDocument() {
        loadGeneration &+= 1
        flushSaveIfNeeded()
        cancelDiffReviewForExternalMutation()
        readSurface = .plain
        syncDiffChrome(show: false)
        clearGhostSuggestion()
        askPinnedRange = nil
        currentDocumentID = nil
        language = .plain
        isPlanDocument = false
        textView.text = ""
        lineNumberView.setNeedsDisplay()
        fileTitleButton.setTitle(nil, for: .normal)
        isDirty = false
        pendingPreviewMarkdown = nil
        previewWebView.evaluateJavaScript("window.__connectsRender && window.__connectsRender('');", completionHandler: nil)
        syncSurfaceVisibility()
        refreshModeChrome()
    }

    func pauseReading() {
        flushSaveIfNeeded()
        textView.resignFirstResponder()
    }

    func prepareForShellLayoutChange() {}
    func beginShellRotation(keeping progress: StudyProgress?) {
        wrapRestoreGeneration &+= 1
        isLivePinching = false
        pinchAttributedSnapshot = nil
        pendingViewportProgress = progress ?? captureReadingProgress()
        if !showsMarkdownPreview {
            let length = (textView.text as NSString?)?.length ?? 0
            pendingViewportUTF16 = sourceUTF16IndexAtTextViewTop(length: max(length, 1))
        }
    }
    func updateDuringShellRotation() {}
    func finishShellRotation(using progress: StudyProgress?) {
        if let progress {
            pendingViewportProgress = progress
        }
        view.layoutIfNeeded()
        lastWrapLayoutWidth = textView.bounds.width
        let pinned = pendingViewportUTF16
        pendingViewportUTF16 = nil
        restoreViewportAfterWrapChange(pinnedUTF16: pinned)
        pendingViewportProgress = nil
        let gen = wrapRestoreGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.wrapRestoreGeneration == gen else { return }
            guard !self.textView.isDragging, !self.textView.isTracking, !self.textView.isDecelerating else { return }
            self.view.layoutIfNeeded()
            self.restoreViewportAfterWrapChange(pinnedUTF16: pinned)
            self.updateLineNumbers(force: true)
            self.syncLineNumberOffset()
        }
    }

    private func restoreViewportAfterWrapChange(pinnedUTF16: Int?) {
        if let idx = pinnedUTF16, !showsMarkdownPreview {
            reflowTextKitForCurrentWidth()
            applyScrollAnchorToTextView(ModeScrollAnchor(sourceUTF16Index: idx, snippet: ""))
            updateLineNumbers(force: true)
            return
        }
        realignVisibleViewport(using: pendingViewportProgress)
    }

    private func reflowTextKitForCurrentWidth() {
        textView.layoutIfNeeded()
        let storageLength = textView.textStorage.length
        guard storageLength > 0 else { return }
        let range = NSRange(location: 0, length: storageLength)
        textView.layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        textView.layoutManager.ensureLayout(for: textView.textContainer)
    }
    func resumeAfterConversationSwitch() {
        syncLineNumberOffset()
    }

    func captureReadingProgress() -> StudyProgress? {
        guard currentDocumentID != nil else { return nil }
        let scroll: UIScrollView = showsMarkdownPreview ? previewWebView.scrollView : textView
        return StudyProgress(
            pageIndex: 0,
            pageOffsetY: scroll.contentOffset.y,
            pageOffsetX: scroll.contentOffset.x,
            scaleFactor: nil,
            updatedAt: Date()
        )
    }

    func saveReadingProgressNow() {
        flushProgressSave()
        flushSaveIfNeeded()
    }

    func realignVisibleViewport(using progress: StudyProgress?) {
        guard let y = progress?.pageOffsetY else { return }
        if showsMarkdownPreview {
            let scroll = previewWebView.scrollView
            let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x: 0, y: min(max(0, y), maxY)), animated: false)
        } else {
            textView.setContentOffset(CGPoint(x: 0, y: max(0, y)), animated: false)
            syncLineNumberOffset()
        }
    }

    func setReaderSurfaceActiveForCapture(_ active: Bool) {
        readerSurfaceActive = active
    }

    func currentPlainText() -> String {
        textView.text ?? ""
    }

    func currentSelectionText() -> String? {
        guard let range = textView.selectedTextRange,
              !range.isEmpty,
              let text = textView.text(in: range)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    /// Text pinned by Ask (survives focus loss); used when the pending store key misses.
    func pinnedAskText() -> String? {
        guard let pinned = askPinnedRange else { return nil }
        let plain = textView.text ?? ""
        let clamped = NSIntersectionRange(pinned, NSRange(location: 0, length: (plain as NSString).length))
        guard clamped.length > 0 else { return nil }
        let text = (plain as NSString).substring(with: clamped)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Persist a visible Ask highlight on the current selection without opening chat.
    func pinAskSelectionHighlight() {
        let range = textView.selectedRange
        let length = (textView.text as NSString?)?.length ?? 0
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
        guard clamped.length > 0 else { return }
        askPinnedRange = clamped
        applyHighlightedText(textView.text ?? "")
        textView.selectedRange = clamped
        dismissAskMenuKeepingSelection()
    }

    func clearAskSelectionHighlight() {
        guard askPinnedRange != nil else { return }
        askPinnedRange = nil
        applyHighlightedText(textView.text ?? "")
    }

    private func dismissAskMenuKeepingSelection() {
        if #available(iOS 13.0, *) {
            UIMenuController.shared.hideMenu(from: textView)
        } else {
            UIMenuController.shared.setMenuVisible(false, animated: true)
        }
    }

    func currentPageLabel() -> String {
        currentFileDisplayName()
    }

    func currentFileDisplayName() -> String {
        guard let id = currentDocumentID,
              let doc = StudyDocumentStore.shared.document(id: id) else { return "无文档" }
        if let path = doc.displayPath, !path.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        let ext = doc.textLanguage?.preferredFileExtension
        if let ext, !doc.title.lowercased().hasSuffix(".\(ext)") {
            return "\(doc.title).\(ext)"
        }
        return doc.title
    }

    func currentPageText() -> String? {
        currentPlainText()
    }

    // MARK: - Private

    @objc private func fileTitleTapped() {
        onFileTitleTapped?(fileTitleButton)
    }

    @objc private func sidebarTapped() {
        onToggleSidebar?()
    }

    @objc private func saveTapped() {
        flushSaveIfNeeded(force: true, showSuccessToast: true)
    }

    @objc private func appearanceTapped() {
        ReaderThemeManager.shared.toggle()
    }

    private func updateAppearanceButton() {
        let dark = ReaderThemeManager.shared.mode == .dark
        let kind: ActionIconFactory.Kind = dark ? .appearanceMoon : .appearanceSun
        appearanceButton.setImage(
            ActionIconFactory.image(kind, pointSize: ActionIconFactory.chromeGlyph),
            for: .normal
        )
        appearanceButton.tintColor = DSTheme.reader.textSecondary
        appearanceButton.accessibilityLabel = dark ? "切换到白天模式" : "切换到黑夜模式"
    }

    @objc private func rotateTapped() {
        onToggleReaderLandscape?()
    }

    @objc private func phoneReaderLandscapeDidChange() {
        updateRotateButtonAppearance()
        syncFileTitlePlacement()
    }

    func syncRotateButtonAppearance() {
        updateRotateButtonAppearance()
        syncFileTitlePlacement()
    }

    private func syncFileTitlePlacement() {
        let phone = ConnectsPhoneReaderLandscape.isPhone
        let landscape = phone && ConnectsPhoneReaderLandscape.isActive
        fileTitleCenterXBar.isActive = !phone || landscape
        fileTitleCenterXSlot.isActive = phone && !landscape
    }

    private func updateRotateButtonAppearance() {
        guard ConnectsPhoneReaderLandscape.isPhone else {
            rotateButton.isHidden = true
            rotateButtonWidthConstraint?.constant = 0
            return
        }
        let on = ConnectsPhoneReaderLandscape.isActive
        let c = DSTheme.reader
        rotateButton.tintColor = on ? c.accent : c.textSecondary
        rotateButton.backgroundColor = on ? c.accent.withAlphaComponent(0.16) : .clear
        rotateButton.layer.cornerRadius = 20
        rotateButton.clipsToBounds = true
        rotateButton.accessibilityLabel = on ? "退出横屏" : "横屏阅读"
    }

    @objc private func themeChanged() {
        let savedProgress = captureReadingProgress()
            ?? StudyProgress(
                pageIndex: 0,
                pageOffsetY: (showsMarkdownPreview ? previewWebView.scrollView : textView).contentOffset.y,
                pageOffsetX: (showsMarkdownPreview ? previewWebView.scrollView : textView).contentOffset.x,
                scaleFactor: nil,
                updatedAt: Date()
            )
        applyChromeColors()
        updateAppearanceButton()
        refreshTextPresentationPreservingDiff()
        updateLineNumbers(force: true)
        syncLineNumberOffset()
        if language == .markdown, showsMarkdownPreview {
            pendingThemeViewportProgress = savedProgress
            previewShellLoaded = false
            refreshMarkdownPreview(text: textView.text ?? "")
        } else {
            // Highlight / chrome refresh can nudge offset — put it back.
            DispatchQueue.main.async { [weak self] in
                self?.realignVisibleViewport(using: savedProgress)
            }
        }
    }

    private func applyChromeColors() {
        let c = DSTheme.reader
        view.backgroundColor = c.background
        topBar.backgroundColor = c.background
        textView.backgroundColor = c.background
        if previewWebView != nil {
            previewWebView.backgroundColor = c.background
            previewWebView.scrollView.backgroundColor = c.background
        }
        gutterView.backgroundColor = c.sidebarBackground
        gutterSeparator.backgroundColor = c.border.withAlphaComponent(0.55)
        topBarSeparator.backgroundColor = c.border.withAlphaComponent(0.55)
        lineNumberView.setNeedsDisplay()
        fileTitleButton.setTitleColor(c.textPrimary, for: .normal)
        modeButton.tintColor = c.textSecondary
        saveButton.tintColor = isEditMode ? c.accent : c.textTertiary
        pinchScaleHost.backgroundColor = c.background
        textView.typingAttributes = CodeSyntaxHighlighter.typingAttributes(fontSize: fontPointSize)
        refreshModeChrome()
        updateRotateButtonAppearance()
    }

    @objc private func handleFontPinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchTargetsPreview = showsMarkdownPreview
            pinchBaseFontSize = pinchTargetsPreview ? markdownPreviewFontSize : fontPointSize
            isLivePinching = !pinchTargetsPreview
            if isLivePinching {
                pinchAttributedSnapshot = textView.attributedText.copy() as? NSAttributedString
                pinchScrollOffset = textView.contentOffset
                capturePinchAnchor(in: textView, at: gesture.location(in: textView))
            }
        case .changed:
            if pinchTargetsPreview {
                let next = min(
                    Self.maxMarkdownPreviewFont,
                    max(Self.minMarkdownPreviewFont, pinchBaseFontSize * gesture.scale)
                )
                guard abs(next - markdownPreviewFontSize) >= 0.4 else { return }
                applyMarkdownPreviewFontSize(next, persist: false)
            } else {
                let next = min(Self.maxFontPointSize, max(Self.minFontPointSize, pinchBaseFontSize * gesture.scale))
                applyLiveFontSize(next)
            }
        case .ended, .cancelled:
            if pinchTargetsPreview {
                applyMarkdownPreviewFontSize(markdownPreviewFontSize, persist: true)
                showFontSizeFeedback(markdownPreviewFontSize)
            } else {
                let next = min(
                    Self.maxFontPointSize,
                    max(Self.minFontPointSize, pinchBaseFontSize * gesture.scale)
                )
                pinchAttributedSnapshot = nil
                isLivePinching = false
                applyFontSize(next, persist: true)
                restorePinchAnchor()
                showFontSizeFeedback(next)
            }
        default:
            break
        }
    }

    private func capturePinchAnchor(in textView: UITextView, at point: CGPoint) {
        if let pos = textView.closestPosition(to: point) {
            pinchAnchorUTF16 = textView.offset(from: textView.beginningOfDocument, to: pos)
        } else {
            pinchAnchorUTF16 = 0
        }
    }

    private func restorePinchAnchor() {
        let text = textView.text ?? ""
        let ns = text as NSString
        guard ns.length > 0 else { return }
        let loc = min(max(pinchAnchorUTF16, 0), ns.length - 1)
        let range = NSRange(location: loc, length: 1)
        textView.layoutIfNeeded()
        textView.scrollRangeToVisible(range)
    }

    private func applyLiveFontSize(_ size: CGFloat) {
        let next = min(Self.maxFontPointSize, max(Self.minFontPointSize, size))
        fontPointSize = next
        guard let snap = pinchAttributedSnapshot else {
            applyFontSize(next, persist: false)
            return
        }
        let painted = NSMutableAttributedString(attributedString: snap)
        let full = NSRange(location: 0, length: painted.length)
        if full.length > 0 {
            painted.addAttribute(.font, value: CodeSyntaxHighlighter.font(size: next), range: full)
            painted.addAttribute(
                .paragraphStyle,
                value: CodeSyntaxHighlighter.paragraphStyle(fontSize: next),
                range: full
            )
        }
        let ratio = next / max(pinchBaseFontSize, 0.1)
        UIView.performWithoutAnimation {
            textView.textStorage.setAttributedString(painted)
            let digits = max(2, "\(max((textView.text ?? "").components(separatedBy: "\n").count, 1))".count)
            gutterWidthConstraint.constant = CodeSyntaxHighlighter.lineNumberGutterWidth(
                digits: digits,
                fontSize: next
            )
            textView.typingAttributes = CodeSyntaxHighlighter.typingAttributes(fontSize: next)
            textView.layoutIfNeeded()
            var offset = CGPoint(x: pinchScrollOffset.x * ratio, y: pinchScrollOffset.y * ratio)
            let scroll = textView
            let maxX = max(0, scroll.contentSize.width - scroll.bounds.width)
            let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
            offset.x = min(max(offset.x, 0), maxX)
            offset.y = min(max(offset.y, 0), maxY)
            textView.setContentOffset(offset, animated: false)
            lineNumberView.fontSize = next
            updateLineNumbers(force: true, allowImmediateLayout: false)
        }
    }

    private func showFontSizeFeedback(_ size: CGFloat) {
        let pt = Int(size.rounded())
        ConnectsToast.show("字号 \(pt)", in: view, duration: 0.7)
    }

    private func applyFontSize(_ size: CGFloat, persist: Bool) {
        fontPointSize = min(Self.maxFontPointSize, max(Self.minFontPointSize, size))
        lineNumberView.fontSize = fontPointSize
        textView.typingAttributes = CodeSyntaxHighlighter.typingAttributes(fontSize: fontPointSize)
        // Diff uses its own attributed paint — never wipe it with plain highlight
        // (that left readSurface=.diff, mode toggle locked, and no way back to edit).
        refreshTextPresentationPreservingDiff()
        updateLineNumbers(force: true)
        syncLineNumberOffset()
        if persist {
            UserDefaults.standard.set(Double(fontPointSize), forKey: Self.fontSizeDefaultsKey)
        }
        if !tabSuggestChip.isHidden {
            repositionTabSuggestChip()
        }
    }

    private func applyMarkdownPreviewFontSize(_ size: CGFloat, persist: Bool) {
        markdownPreviewFontSize = min(Self.maxMarkdownPreviewFont, max(Self.minMarkdownPreviewFont, size))
        if persist {
            UserDefaults.standard.set(Double(markdownPreviewFontSize), forKey: Self.markdownPreviewFontDefaultsKey)
        }
        guard previewWebView != nil, previewShellLoaded else { return }
        previewWebView.evaluateJavaScript(
            MarkdownHTMLRenderer.setFontSizeJavaScript(markdownPreviewFontSize),
            completionHandler: nil
        )
    }

    /// Re-paint editor text at the current font/theme without exiting Diff review.
    private func refreshTextPresentationPreservingDiff() {
        switch readSurface {
        case .diff:
            guard !diffSegments.isEmpty else { return }
            reloadDiffRendering()
            positionDiffHunkBar(animatedScroll: false)
        case .diffPreview:
            let text = diffAfterSnapshot
                ?? CodeTextDiff.compose(diffSegments, pendingAsUndone: false)
            applyHighlightedText(text)
        case .plain:
            applyHighlightedText(textView.text ?? "")
        }
    }

    private var isDiffSessionActive: Bool {
        readSurface == .diff || readSurface == .diffPreview
    }

    private func bumpFontSize(by delta: CGFloat) {
        if showsMarkdownPreview {
            let next = min(
                Self.maxMarkdownPreviewFont,
                max(Self.minMarkdownPreviewFont, markdownPreviewFontSize + delta)
            )
            guard abs(next - markdownPreviewFontSize) >= 0.1 else { return }
            applyMarkdownPreviewFontSize(next, persist: true)
            showFontSizeFeedback(next)
            return
        }
        let next = min(Self.maxFontPointSize, max(Self.minFontPointSize, fontPointSize + delta))
        guard abs(next - fontPointSize) >= 0.1 else { return }
        applyFontSize(next, persist: true)
        showFontSizeFeedback(next)
    }

    /// Shell / hardware keyboard: ⌘+ / ⌘- (VS Code–style zoom).
    func adjustFontSizeFromKeyboardShortcut(by delta: CGFloat) {
        bumpFontSize(by: delta)
    }

    /// Shell / hardware keyboard: ⌘M toggles read(preview) ↔ edit (or Diff ↔ 预览 while reviewing).
    func toggleEditModeFromKeyboardShortcut() {
        if isDiffSessionActive {
            // Broken / empty Diff: escape instead of trapping ⌘M.
            if readSurface == .diff,
               (diffSegments.isEmpty || CodeTextDiff.pendingHunkIndices(in: diffSegments).isEmpty) {
                abandonDiffReviewReturningToRead()
                return
            }
            toggleDiffVersusKeptPreview()
            return
        }
        let next = !isEditMode
        applyEditMode(next)
        // Don't auto-focus — wait until the user taps into the editor.
    }

    /// Leave edit mode without focusing (used when jumping to AI input).
    func leaveEditModeFromKeyboardShortcut() {
        guard isEditMode else { return }
        applyEditMode(false)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UIPinchGestureRecognizer
    }

    @objc private func modeTapped() {
        if isDiffSessionActive {
            // Diff ↔ 提案预览 only — never abandon Diff here (Keep/Undo exits).
            if readSurface == .diff,
               (diffSegments.isEmpty || CodeTextDiff.pendingHunkIndices(in: diffSegments).isEmpty) {
                abandonDiffReviewReturningToRead()
                return
            }
            toggleDiffVersusKeptPreview()
            return
        }
        let next = !isEditMode
        applyEditMode(next)
        if !next {
            // Ensure chrome reflects read mode even if focus handoff raced.
            refreshModeChrome()
        }
        liftTopChrome()
    }

    /// Leave Diff review and restore normal read mode (pending hunks discarded like Undo All).
    private func abandonDiffReviewReturningToRead() {
        if isDiffSessionActive,
           !diffSegments.isEmpty,
           !CodeTextDiff.pendingHunkIndices(in: diffSegments).isEmpty {
            diffUndoAll()
        } else {
            cancelDiffReviewForExternalMutation()
            ConnectsToast.show("已退出 Diff", in: view, duration: 1.0)
        }
        applyEditMode(false)
    }

    /// Mode / ⌘M while reviewing: Diff hunks ↔ kept preview (Diff stays active).
    private func toggleDiffVersusKeptPreview() {
        if readSurface == .diff {
            enterDiffKeptPreview()
        } else if readSurface == .diffPreview {
            enterDiffHunkSurface()
        }
    }

    private func enterDiffKeptPreview() {
        guard diffBeforeSnapshot != nil else {
            abandonDiffReviewReturningToRead()
            return
        }
        readSurface = .diffPreview
        diffHunkBar.isHidden = true
        clearPerHunkActionBars()
        let text = diffAfterSnapshot
            ?? CodeTextDiff.compose(diffSegments, pendingAsUndone: false)
        applyHighlightedText(text)
        updateLineNumbers(force: true)
        refreshModeChrome()
        refreshTabToggleChrome()
        updateProgressLabel()
        syncSurfaceVisibility()
        notifyDiffSessionChange()
    }

    private func enterDiffHunkSurface() {
        guard diffBeforeSnapshot != nil, !diffSegments.isEmpty else {
            abandonDiffReviewReturningToRead()
            return
        }
        readSurface = .diff
        reloadDiffRendering()
        syncDiffChrome(show: true)
        refreshModeChrome()
        refreshTabToggleChrome()
        updateProgressLabel()
        syncSurfaceVisibility()
        positionDiffHunkBar(animatedScroll: false)
        notifyDiffSessionChange()
    }

    /// Keyboard shortcut: enter edit mode and focus the code text view.
    func focusForKeyboardEditing() {
        applyEditMode(true)
        // Focus immediately and retry next turn — shell `endEditing` / first-responder
        // handoff often needs a bounce before UITextView accepts the keyboard.
        let attemptFocus = { [weak self] in
            guard let self = self, self.isEditMode, !self.showsMarkdownPreview else { return }
            self.textView.isHidden = false
            self.textView.isUserInteractionEnabled = true
            _ = self.textView.becomeFirstResponder()
        }
        attemptFocus()
        if !textView.isFirstResponder {
            DispatchQueue.main.async(execute: attemptFocus)
        }
    }

    /// True while the editor is in edit mode (keyboard may or may not be up).
    var isInEditMode: Bool { isEditMode }

    var isCodeEditorFirstResponder: Bool {
        textView.isFirstResponder
    }

    func saveFromKeyboardShortcut() {
        flushSaveIfNeeded(force: true, showSuccessToast: true)
    }

    private func applyEditMode(_ editing: Bool) {
        if isDiffSessionActive {
            // Diff session: never enter edit; mode key toggles Diff ↔ preview instead.
            if editing { return }
            // Allow leaving edit if somehow stuck (should not happen).
        }

        let wasShowingMarkdownPreview = showsMarkdownPreview
        let willShowMarkdownPreview = language == .markdown && !editing && readSurface == .plain
        let switchingMarkdownSurface = language == .markdown && !isDiffSessionActive
            && wasShowingMarkdownPreview != willShowMarkdownPreview

        if switchingMarkdownSurface {
            if wasShowingMarkdownPreview {
                // Preview → edit: resolve top-of-viewport text first (async JS).
                if pendingModeScrollAnchor == nil {
                    if isResolvingPreviewScrollAnchor { return }
                    isResolvingPreviewScrollAnchor = true
                    capturePreviewTopAnchor { [weak self] anchor in
                        guard let self else { return }
                        self.isResolvingPreviewScrollAnchor = false
                        self.pendingModeScrollAnchor = anchor
                        self.applyEditMode(true)
                    }
                    return
                }
            } else {
                // Edit → preview: pin whatever is under the editor's top edge.
                pendingModeScrollAnchor = captureTextViewTopAnchor()
            }
        } else {
            pendingModeScrollAnchor = nil
        }

        if !editing {
            // Avoid flush/resign during viewDidLoad (view not in a window yet).
            if isViewLoaded, view.window != nil {
                flushSaveIfNeeded(force: true)
                textView.resignFirstResponder()
            }
            clearGhostSuggestion()
        }
        isEditMode = editing
        textView.isEditable = editing && !isDiffSessionActive
        textView.isSelectable = true
        refreshModeChrome()
        refreshTabToggleChrome()
        updateProgressLabel()
        syncSurfaceVisibility()
        if showsMarkdownPreview {
            refreshMarkdownPreview(text: textView.text ?? "")
            // Scroll restore waits for inject completion (contentSize not ready yet).
        } else if switchingMarkdownSurface, let anchor = pendingModeScrollAnchor {
            pendingModeScrollAnchor = nil
            // Layout may still be settling after un-hiding textView.
            applyScrollAnchorToTextView(anchor)
            DispatchQueue.main.async { [weak self] in
                self?.applyScrollAnchorToTextView(anchor)
            }
        }
    }

    private func refreshModeChrome() {
        let c = DSTheme.reader
        if isDiffSessionActive {
            // During Diff: button means "switch Diff / 阅读预览".
            let showingDiff = readSurface == .diff
            let modeKind: ActionIconFactory.Kind = showingDiff ? .readMode : .editMode
            modeButton.setTitle(nil, for: .normal)
            modeButton.setImage(ActionIconFactory.image(modeKind, pointSize: ActionIconFactory.chromeGlyph), for: .normal)
            modeButton.tintColor = c.accent
            modeButton.isEnabled = true
            modeButton.alpha = 1
            modeButton.accessibilityLabel = showingDiff
                ? "查看提案预览（全部 Keep）"
                : "返回 Diff"
        } else {
            let modeKind: ActionIconFactory.Kind = isEditMode ? .readMode : .editMode
            modeButton.setTitle(nil, for: .normal)
            modeButton.setImage(ActionIconFactory.image(modeKind, pointSize: ActionIconFactory.chromeGlyph), for: .normal)
            // Accent while editing so the toggle is visibly “on”.
            modeButton.tintColor = isEditMode ? c.accent : c.textSecondary
            modeButton.isEnabled = true
            modeButton.isUserInteractionEnabled = true
            modeButton.alpha = 1
            if language == .markdown {
                modeButton.accessibilityLabel = isEditMode ? "切换到预览模式" : "切换到编辑模式"
            } else {
                modeButton.accessibilityLabel = isEditMode ? "切换到阅读模式" : "切换到编辑模式"
            }
        }
        saveButton.setTitle(nil, for: .normal)
        saveButton.setImage(ActionIconFactory.image(.save, pointSize: ActionIconFactory.chromeGlyph), for: .normal)
        saveButton.isHidden = false
        saveButton.isEnabled = isEditMode && !isDiffSessionActive
        saveButton.alpha = saveButton.isEnabled ? 1 : 0.35
        saveButton.tintColor = saveButton.isEnabled ? c.accent : c.textTertiary
        updateBuildButtonVisibility()
    }

    @objc private func buildTapped() {
        onBuildPlan?()
    }

    private func updateBuildButtonVisibility() {
        let show = language == .markdown && isPlanDocument && onBuildPlan != nil && !isDiffSessionActive
        buildButton.isHidden = !show
        buildButtonWidthConstraint.constant = show ? 56 : 0
        buildButton.setTitleColor(DSTheme.reader.accent, for: .normal)
        buildButton.isUserInteractionEnabled = show
        if show {
            topBar.bringSubviewToFront(buildButton)
        }
    }

    private func recomputePlanFlagFromEditorText() {
        guard language == .markdown else {
            isPlanDocument = false
            return
        }
        isPlanDocument = StudyPlanDocument.parse(textView.text ?? "").isPlan
    }

    private func syncSurfaceVisibility() {
        let preview = showsMarkdownPreview
        previewWebView.isHidden = !preview
        previewWebView.isUserInteractionEnabled = preview
        textView.isHidden = preview
        gutterView.isHidden = preview
        gutterSeparator.isHidden = preview
        lineNumberView.isHidden = preview
        if preview {
            previewWebView.scrollView.isScrollEnabled = true
            view.bringSubviewToFront(previewWebView)
            view.bringSubviewToFront(spinner)
            // Keep live size if shell was built earlier at a different pt.
            applyMarkdownPreviewFontSize(markdownPreviewFontSize, persist: false)
        }
        liftTopChrome()
    }

    private func refreshMarkdownPreview(text: String) {
        refreshPreviewAssetCatalog()
        loadPreviewShellIfNeeded()
        pendingPreviewMarkdown = MarkdownPreviewAssetIndex.rewriteForPreview(
            text,
            catalog: previewAssetHandler.catalog
        )
        tryInjectPendingPreview()
        // Ensure WK scroll is live after shell (re)load / theme.
        previewWebView.scrollView.isScrollEnabled = true
    }

    private func refreshPreviewAssetCatalog() {
        guard let id = currentDocumentID,
              let folder = StudyDocumentStore.shared.documentFolderURL(forID: id) else {
            previewAssetHandler.catalog = nil
            return
        }
        previewAssetHandler.catalog = MarkdownPreviewAssetIndex.catalog(documentFolder: folder)
    }

    private func presentPreviewAsset(href: String) {
        if let loaded = MarkdownPreviewAssetIndex.loadImage(href: href, catalog: previewAssetHandler.catalog) {
            let vc = StudyAssetImageViewController(image: loaded.image, title: loaded.title)
            present(vc, animated: true)
            return
        }
        let alert = UIAlertController(
            title: "无法打开图片",
            message: "未在同目录 ./assets（或 ./asset）中找到该文件。\n\(href)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "studyAsset" else { return }
        let href: String
        if let s = message.body as? String {
            href = s
        } else {
            href = "\(message.body)"
        }
        presentPreviewAsset(href: href)
    }

    private func loadPreviewShellIfNeeded() {
        guard !previewShellLoaded else { return }
        let html = MarkdownHTMLRenderer.studyShellHTML(
            textColor: DSTheme.reader.textPrimary,
            backgroundColor: DSTheme.reader.background,
            secondaryColor: DSTheme.reader.textSecondary,
            fontSize: markdownPreviewFontSize
        )
        previewWebView.loadHTMLString(html, baseURL: MarkdownHTMLRenderer.resourceBaseURL)
    }

    private func tryInjectPendingPreview() {
        guard previewShellLoaded, let md = pendingPreviewMarkdown else { return }
        pendingPreviewMarkdown = nil
        let js = MarkdownHTMLRenderer.renderJavaScript(content: md)
        previewWebView.evaluateJavaScript(js) { [weak self] _, _ in
            // Render JS schedules double-rAF before studyReady; wait a beat for contentSize.
            DispatchQueue.main.async {
                self?.applyPendingModeScrollToPreview(clearPending: false)
                self?.applyPendingThemeViewportToPreview(clearPending: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    self?.applyPendingModeScrollToPreview(clearPending: true)
                    self?.applyPendingThemeViewportToPreview(clearPending: true)
                }
            }
        }
    }

    private func applyPendingThemeViewportToPreview(clearPending: Bool) {
        guard showsMarkdownPreview, let progress = pendingThemeViewportProgress else { return }
        let scroll = previewWebView.scrollView
        scroll.layoutIfNeeded()
        guard scroll.contentSize.height > 8 else { return }
        realignVisibleViewport(using: progress)
        if clearPending {
            pendingThemeViewportProgress = nil
        }
    }

    // MARK: - Markdown edit ↔ preview scroll anchor (viewport top)

    /// Source index + snippet for the line under the editor's top edge.
    private func captureTextViewTopAnchor() -> ModeScrollAnchor {
        let text = textView.text ?? ""
        let ns = text as NSString
        let length = ns.length
        guard length > 0 else {
            return ModeScrollAnchor(sourceUTF16Index: 0, snippet: "")
        }
        textView.layoutIfNeeded()
        let index = sourceUTF16IndexAtTextViewTop(length: length)
        let snippet = snippetNearSourceIndex(index, in: ns)
        return ModeScrollAnchor(sourceUTF16Index: index, snippet: snippet)
    }

    private func sourceUTF16IndexAtTextViewTop(length: Int) -> Int {
        let layoutManager = textView.layoutManager
        layoutManager.ensureLayout(for: textView.textContainer)
        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0, length > 0 else { return 0 }
        var fraction: CGFloat = 0
        let containerY = max(
            0,
            textView.contentOffset.y
                + textView.adjustedContentInset.top
                - textView.textContainerInset.top
        )
        let glyphIndex = layoutManager.glyphIndex(
            for: CGPoint(x: textView.textContainer.lineFragmentPadding + 1, y: containerY + 1),
            in: textView.textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        let charIndex = layoutManager.characterIndexForGlyph(at: min(max(0, glyphIndex), glyphCount - 1))
        return min(max(0, charIndex), length - 1)
    }

    private func snippetNearSourceIndex(_ index: Int, in ns: NSString) -> String {
        guard ns.length > 0 else { return "" }
        let lineRange = ns.lineRange(for: NSRange(location: min(index, max(0, ns.length - 1)), length: 0))
        var line = ns.substring(with: lineRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip common Markdown markers so preview plain text can match.
        while line.hasPrefix("#") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if line.hasPrefix(">") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            line = String(line.dropFirst(2))
        }
        line = line.replacingOccurrences(of: "**", with: "")
        line = line.replacingOccurrences(of: "__", with: "")
        line = line.replacingOccurrences(of: "*", with: "")
        line = line.replacingOccurrences(of: "`", with: "")
        if line.count > 64 {
            line = String(line.prefix(64))
        }
        return line
    }

    private func capturePreviewTopAnchor(completion: @escaping (ModeScrollAnchor) -> Void) {
        let js = "window.__connectsTopViewportSnippet ? window.__connectsTopViewportSnippet(80) : ''"
        previewWebView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else {
                completion(ModeScrollAnchor(sourceUTF16Index: 0, snippet: ""))
                return
            }
            let snippet = ((result as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let text = self.textView.text ?? ""
            let ns = text as NSString
            let index: Int
            if let found = self.sourceUTF16Index(matching: snippet, in: ns) {
                index = found
            } else {
                // Fallback: map viewport top through document height → source index.
                index = self.approximateSourceIndexFromPreviewScrollTop(length: ns.length)
            }
            completion(ModeScrollAnchor(sourceUTF16Index: index, snippet: snippet))
        }
    }

    private func sourceUTF16Index(matching snippet: String, in ns: NSString) -> Int? {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, ns.length > 0 else { return nil }
        var needles: [String] = [trimmed]
        if trimmed.count > 24 {
            needles.append(String(trimmed.prefix(24)))
        }
        if trimmed.count > 12 {
            needles.append(String(trimmed.prefix(12)))
        }
        for needle in needles where needle.count >= 2 {
            let range = ns.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
            if range.location != NSNotFound {
                return range.location
            }
        }
        return nil
    }

    private func approximateSourceIndexFromPreviewScrollTop(length: Int) -> Int {
        guard length > 0 else { return 0 }
        let scroll = previewWebView.scrollView
        let contentH = max(1, scroll.contentSize.height)
        let top = max(0, scroll.contentOffset.y + scroll.adjustedContentInset.top)
        let fraction = min(max(0, top / contentH), 1)
        return min(max(0, Int((fraction * CGFloat(length)).rounded(.down))), length - 1)
    }

    private func applyScrollAnchorToTextView(_ anchor: ModeScrollAnchor) {
        let text = textView.text ?? ""
        let length = (text as NSString).length
        guard length > 0, textView.bounds.width > 8, textView.bounds.height > 8 else { return }
        textView.layoutIfNeeded()
        let layoutManager = textView.layoutManager
        layoutManager.ensureLayout(for: textView.textContainer)
        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0 else { return }
        let charIndex = min(max(0, anchor.sourceUTF16Index), length - 1)
        let glyphIndex = min(layoutManager.glyphIndexForCharacter(at: charIndex), glyphCount - 1)
        var effectiveRange = NSRange(location: 0, length: 0)
        let lineRect = layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex,
            effectiveRange: &effectiveRange
        )
        let used = layoutManager.usedRect(for: textView.textContainer)
        let inset = textView.textContainerInset
        let contentH = max(
            textView.contentSize.height,
            ceil(used.maxY + inset.top + inset.bottom)
        )
        let maxY = max(0, contentH - textView.bounds.height)
        let targetY = lineRect.minY + inset.top - textView.adjustedContentInset.top
        let y = min(max(0, targetY), maxY)
        textView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        syncLineNumberOffset()
    }

    private func applyScrollAnchorToPreview(_ anchor: ModeScrollAnchor) {
        let scroll = previewWebView.scrollView
        scroll.layoutIfNeeded()
        let snippetJSON = MarkdownHTMLRenderer.jsonString(anchor.snippet)
        let sourceLen = max(((textView.text ?? "") as NSString).length, 1)
        let js = """
        (function(){
          var snip = \(snippetJSON);
          if (window.__connectsScrollSnippetToTop && snip && snip.length > 0) {
            if (window.__connectsScrollSnippetToTop(snip)) return true;
          }
          var len = \(sourceLen);
          var idx = \(anchor.sourceUTF16Index);
          var frac = len > 0 ? Math.min(1, Math.max(0, idx / len)) : 0;
          var el = document.getElementById("c") || document.body;
          var h = Math.max(el.scrollHeight || 0, document.documentElement.scrollHeight || 0);
          var viewH = window.innerHeight || document.documentElement.clientHeight || 0;
          var y = Math.max(0, Math.min(h - viewH, frac * h));
          if (window.scrollTo) window.scrollTo(0, y);
          return false;
        })();
        """
        previewWebView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func applyPendingModeScrollToPreview(clearPending: Bool) {
        guard showsMarkdownPreview, let anchor = pendingModeScrollAnchor else { return }
        let scroll = previewWebView.scrollView
        scroll.layoutIfNeeded()
        // Content not measured yet — keep pending for a later retry.
        guard scroll.contentSize.height > 8 else { return }
        applyScrollAnchorToPreview(anchor)
        if clearPending {
            pendingModeScrollAnchor = nil
        }
    }

    private var isIMEComposing: Bool {
        textView.markedTextRange != nil
    }

    /// UTF-16 caret/selection snapshot that survives attributed-string swaps.
    private func captureCaretSnapshot() -> (location: Int, length: Int, contentOffset: CGPoint) {
        let offset = textView.contentOffset
        if let selected = textView.selectedTextRange {
            let loc = textView.offset(from: textView.beginningOfDocument, to: selected.start)
            let len = textView.offset(from: selected.start, to: selected.end)
            return (max(0, loc), max(0, len), offset)
        }
        let range = textView.selectedRange
        return (range.location, range.length, offset)
    }

    private func restoreCaret(location: Int, length: Int, contentOffset: CGPoint?) {
        let maxLen = textView.textStorage.length
        let loc = max(0, min(location, maxLen))
        let len = max(0, min(length, maxLen - loc))
        if let start = textView.position(from: textView.beginningOfDocument, offset: loc),
           let end = textView.position(from: start, offset: len),
           let range = textView.textRange(from: start, to: end) {
            textView.selectedTextRange = range
        } else {
            textView.selectedRange = NSRange(location: loc, length: len)
        }
        // Only pin scroll when not editing. While first-responder, UITextView
        // scrolls to keep the caret visible — forcing an old offset fights that
        // and makes the page jump up/down after each highlight pass.
        guard let contentOffset = contentOffset else { return }
        if abs(textView.contentOffset.y - contentOffset.y) > 0.5
            || abs(textView.contentOffset.x - contentOffset.x) > 0.5 {
            textView.setContentOffset(contentOffset, animated: false)
        }
    }

    private func applyHighlightedText(_ text: String) {
        // Diff review owns the attributed string; callers that need a font/theme
        // refresh must use `refreshTextPresentationPreservingDiff` instead.
        guard readSurface != .diff else { return }
        guard !isIMEComposing else { return }
        let caret = captureCaretSnapshot()
        let editing = textView.isFirstResponder
        isApplyingHighlight = true
        defer { isApplyingHighlight = false }

        var attributed: NSAttributedString = CodeSyntaxHighlighter.highlight(
            text,
            language: language,
            fontSize: fontPointSize
        )
        if let pinned = askPinnedRange {
            let length = (text as NSString).length
            let clamped = NSIntersectionRange(pinned, NSRange(location: 0, length: length))
            if clamped.length > 0, let mutable = attributed.mutableCopy() as? NSMutableAttributedString {
                let tint = DSTheme.reader.accent.withAlphaComponent(0.28)
                mutable.addAttribute(.backgroundColor, value: tint, range: clamped)
                attributed = mutable
            } else {
                askPinnedRange = nil
            }
        }

        let storage = textView.textStorage
        // After keystrokes the plain string is already in textStorage. Replacing the
        // whole attributed string reflows layout and resets scroll — paint colors only.
        let samePlainText = storage.string == attributed.string
        UIView.performWithoutAnimation {
            storage.beginEditing()
            if samePlainText, storage.length == attributed.length {
                let full = NSRange(location: 0, length: attributed.length)
                attributed.enumerateAttributes(in: full, options: []) { attrs, range, _ in
                    storage.setAttributes(attrs, range: range)
                }
            } else {
                storage.setAttributedString(attributed)
            }
            storage.endEditing()

            let now = textView.selectedRange
            let caretMoved = now.location != caret.location || now.length != caret.length
            if caretMoved || !samePlainText {
                // Never force contentOffset while typing — that causes the visible jump.
                restoreCaret(
                    location: caret.location,
                    length: caret.length,
                    contentOffset: editing ? nil : caret.contentOffset
                )
            } else if !editing {
                restoreCaret(
                    location: caret.location,
                    length: caret.length,
                    contentOffset: caret.contentOffset
                )
            }
        }

        textView.typingAttributes = CodeSyntaxHighlighter.typingAttributes(fontSize: fontPointSize)
        syncLineNumberOffset()
    }

    private func scheduleHighlight() {
        highlightWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.readSurface == .diff { return }
            if self.isIMEComposing {
                // Keep waiting until composition ends — do not paint over marked text.
                self.scheduleHighlight()
                return
            }
            self.applyHighlightedText(self.textView.text ?? "")
            // Refresh gutter after highlight; avoid layoutIfNeeded while typing.
            self.updateLineNumbers(force: true, allowImmediateLayout: !self.textView.isFirstResponder)
        }
        highlightWorkItem = work
        // Slightly longer debounce so mid-token Latin typing is less likely to
        // fight the keyboard; still snappy after a short pause / word boundary.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func scheduleAutosave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushSaveIfNeeded(force: true)
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func flushSaveIfNeeded(force: Bool = false, showSuccessToast: Bool = false) {
        guard currentDocumentID != nil, isDirty || force else { return }
        guard isDirty else { return }
        let text = textView.text ?? ""
        guard let docID = currentDocumentID else { return }
        do {
            try StudyDocumentStore.shared.writeTextContent(text, for: docID)
            isDirty = false
            updateProgressLabel()
            if let conv = conversationIDForDirty {
                StudyFileContextStore.shared.markDirty(conversationID: conv)
            }
            onContentEdited?()
            if showSuccessToast {
                ConnectsToast.show("已保存", in: view, duration: 1.0)
            }
        } catch {
            ConnectsToast.show("保存失败：\(error.localizedDescription)", in: view, duration: 2.0)
        }
    }

    private func flushProgressSave() {
        guard let docID = currentDocumentID,
              let progress = captureReadingProgress() else { return }
        StudyProgressStore.shared.update(documentID: docID, progress: progress)
    }

    private func updateLineNumbers(force: Bool = false, allowImmediateLayout: Bool = true) {
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let text = textView.text ?? ""
        let lineCount = max(1, text.components(separatedBy: "\n").count)
        let digits = "\(lineCount)".count
        let targetGutter = CodeSyntaxHighlighter.lineNumberGutterWidth(
            digits: digits,
            fontSize: fontPointSize
        )
        let gutterChanged = abs(gutterWidthConstraint.constant - targetGutter) > 0.5
        if gutterChanged {
            gutterWidthConstraint.constant = targetGutter
            // Synchronous layout while typing changes editor width → soft-wrap
            // reflow → visible vertical jump. Defer until the next layout pass.
            if allowImmediateLayout, !textView.isFirstResponder {
                view.layoutIfNeeded()
            }
        }
        lineNumberView.fontSize = fontPointSize
        lineNumberView.setNeedsDisplay()
        _ = force
    }

    private func syncLineNumberOffset() {
        lineNumberView.setNeedsDisplay()
    }

    private func updateProgressLabel() {
        let name = currentFileDisplayName()
        let dirty = (isEditMode && isDirty) ? " ·" : ""
        fileTitleButton.setTitle(name == "无文档" ? name : "\(name) ▾\(dirty)", for: .normal)
    }

    // MARK: - UITextViewDelegate

    func textView(_ textView: UITextView,
                  shouldChangeTextIn range: NSRange,
                  replacementText text: String) -> Bool {
        guard textView === self.textView, isEditMode else { return true }
        guard textView.markedTextRange == nil else { return true }
        guard text == "\n" else { return true }

        let full = textView.text ?? ""
        let insertion = CodeEditorIndent.insertionAfterNewline(
            fullText: full,
            location: range.location,
            language: language
        )
        // Insert via textStorage so existing highlight attributes are kept —
        // assigning `textView.text` would wipe colors until the next highlight pass.
        let attrs = CodeSyntaxHighlighter.typingAttributes(fontSize: fontPointSize)
        let attributed = NSAttributedString(string: insertion, attributes: attrs)
        let caret = range.location + (insertion as NSString).length
        textView.textStorage.beginEditing()
        textView.textStorage.replaceCharacters(in: range, with: attributed)
        textView.textStorage.endEditing()
        textView.selectedRange = NSRange(location: caret, length: 0)
        textView.typingAttributes = attrs
        textViewDidChange(textView)
        return false
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !isApplyingHighlight else { return }
        if askPinnedRange != nil {
            askPinnedRange = nil
        }
        isDirty = true
        if language == .markdown {
            recomputePlanFlagFromEditorText()
            updateBuildButtonVisibility()
        }
        updateProgressLabel()
        // Line numbers refresh after debounced highlight. Doing ensureLayout +
        // gutter work on every keystroke fights soft-wrap and scrolls the page.
        onPageChanged?()
        // Replacing attributes during IME composition commits raw pinyin letters.
        guard !isIMEComposing else { return }
        scheduleHighlight()
        scheduleAutosave()
        clearGhostSuggestion()
        scheduleTabCompletion()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        // Apply any deferred gutter width change now that reflow won't yank the caret.
        updateLineNumbers(force: true, allowImmediateLayout: true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Page stays left/right locked; formula boxes handle their own horizontal pan in-DOM.
        if previewWebView != nil, scrollView === previewWebView.scrollView {
            if abs(scrollView.contentOffset.x) > 0.5 {
                scrollView.contentOffset.x = 0
            }
            return
        }
        guard scrollView === textView else { return }
        syncLineNumberOffset()
        if !tabSuggestChip.isHidden {
            repositionTabSuggestChip()
        }
        if readSurface == .diff {
            // Bars live in textView content space — only refresh focus / trailing X, not Y remap.
            syncDiffIndexFromViewport()
            layoutPerHunkActionBarsInContent()
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === textView else { return }
        if !decelerate { onPageChanged?() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === textView else { return }
        onPageChanged?()
    }

#if DEBUG
    func debugEditorContentOffsetY() -> CGFloat { textView.contentOffset.y }
    func debugLineNumberContentOffsetY() -> CGFloat { textView.contentOffset.y }
    func debugScrollEditor(by dy: CGFloat) {
        let y = min(max(0, textView.contentOffset.y + dy),
                    max(0, textView.contentSize.height - textView.bounds.height))
        textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: y), animated: false)
        syncLineNumberOffset()
        if readSurface == .diff {
            syncDiffIndexFromViewport()
            layoutPerHunkActionBarsInContent()
        }
        if !tabSuggestChip.isHidden {
            repositionTabSuggestChip()
        }
    }
    func debugSetEditMode(_ editing: Bool) {
        applyEditMode(editing)
        view.layoutIfNeeded()
    }
    func debugTopChromeFrames() -> (mode: CGRect, save: CGRect) {
        (modeButton.convert(modeButton.bounds, to: view),
         saveButton.convert(saveButton.bounds, to: view))
    }

    /// Pending-ord label text (`"2/16"`) for Diff nav QA.
    func debugDiffNavLabelText() -> String { diffNavLabel.text ?? "" }

    /// Per-hunk Keep/Undo bar frames in editor view coords, keyed by segment index.
    func debugDiffPerHunkBarFrames() -> [Int: CGRect] {
        var out: [Int: CGRect] = [:]
        for bar in diffPerHunkBars where !bar.isHidden {
            out[bar.tag] = textView.convert(bar.frame, to: view)
        }
        return out
    }

    /// Content-space Y cache for pending hunks.
    func debugDiffHunkDocY() -> [Int: (minY: CGFloat, maxY: CGFloat)] { diffHunkDocY }

    func debugShowTabSuggestion(_ text: String) {
        showGhostSuggestion(text)
    }

    func debugSetSelectedLocation(_ location: Int) {
        let len = (textView.text as NSString?)?.length ?? 0
        let loc = min(max(0, location), len)
        textView.selectedRange = NSRange(location: loc, length: 0)
    }

    func debugTabSuggestChipFrame() -> CGRect {
        tabSuggestChip.isHidden ? .null : tabSuggestChip.frame
    }

    func debugAcceptTabSuggestion() {
        acceptGhostSuggestion()
    }

    /// Expected Keep/Undo bar origin.y in **editor view** coords for a pending hunk (content-space host).
    func debugExpectedHunkBarY(segIdx: Int) -> CGFloat? {
        guard let doc = diffHunkDocY[segIdx] else { return nil }
        let barH: CGFloat = 34
        let yContent = doc.maxY - barH * 0.5
        return textView.convert(CGPoint(x: 0, y: yContent), to: view).y
    }

    func debugDiffCurrentPendingOrdinal() -> Int { diffCurrentPendingIndex }

    func diffNextHunkForQA() { diffNextHunk() }
    func diffPrevHunkForQA() { diffPrevHunk() }
    func diffKeepCurrentHunkForQA() { decideCurrentHunk(keep: true) }
#endif
}

// MARK: - Hardware keyboard (editor-local)

extension TextCodeEditorViewController {
    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        // Published on VC + StudyAskTextView (via provider) so shortcuts work in
        // read/preview and while the text view is first responder.
        var commands: [UIKeyCommand] = [
            makeEditorKeyCommand(input: "=", modifiers: .command,
                                 action: #selector(shortcutFontLarger), title: "增大代码字号"),
            makeEditorKeyCommand(input: "+", modifiers: .command,
                                 action: #selector(shortcutFontLarger), title: "增大代码字号"),
            makeEditorKeyCommand(input: "+", modifiers: [.command, .shift],
                                 action: #selector(shortcutFontLarger), title: "增大代码字号"),
            makeEditorKeyCommand(input: "-", modifiers: .command,
                                 action: #selector(shortcutFontSmaller), title: "减小代码字号"),
            makeEditorKeyCommand(input: "_", modifiers: [.command, .shift],
                                 action: #selector(shortcutFontSmaller), title: "减小代码字号"),
            makeEditorKeyCommand(input: "m", modifiers: .command,
                                 action: #selector(shortcutToggleEditMode), title: "切换阅读 / 编辑"),
            makeEditorKeyCommand(input: UIKeyCommand.inputUpArrow, modifiers: .alternate,
                                 action: #selector(shortcutJumpLinesUp), title: "上移 5 行"),
            makeEditorKeyCommand(input: UIKeyCommand.inputDownArrow, modifiers: .alternate,
                                 action: #selector(shortcutJumpLinesDown), title: "下移 5 行"),
            makeEditorKeyCommand(input: UIKeyCommand.inputLeftArrow, modifiers: .alternate,
                                 action: #selector(shortcutLineStart), title: "跳到文字行首"),
            makeEditorKeyCommand(input: UIKeyCommand.inputRightArrow, modifiers: .alternate,
                                 action: #selector(shortcutLineEnd), title: "跳到文字行末"),
            makeEditorKeyCommand(input: "y", modifiers: [],
                                 action: #selector(shortcutDiffAccept), title: "Keep Diff"),
            makeEditorKeyCommand(input: "n", modifiers: [],
                                 action: #selector(shortcutDiffReject), title: "Undo Diff")
        ]
        if CodeEditorFeatureFlags.tabCompletionEnabled {
            commands.insert(
                makeEditorKeyCommand(input: "\t", modifiers: [],
                                     action: #selector(shortcutAcceptGhost), title: "Accept Tab"),
                at: commands.count - 2
            )
        }
        return commands
    }

    @objc private func shortcutAcceptGhost() {
        _ = keyCommandsAcceptGhostOrPass()
    }

    @objc private func shortcutDiffAccept() {
        guard readSurface == .diff else { return }
        diffKeepHunk()
    }

    @objc private func shortcutDiffReject() {
        guard readSurface == .diff else { return }
        diffUndoHunk()
    }

    private func makeEditorKeyCommand(input: String,
                                      modifiers: UIKeyModifierFlags,
                                      action: Selector,
                                      title: String) -> UIKeyCommand {
        let cmd = UIKeyCommand(title: title, action: action, input: input, modifierFlags: modifiers)
        cmd.wantsPriorityOverSystemBehavior = true
        return cmd
    }

    @objc private func shortcutJumpLinesUp() {
        moveCaretByLines(-5)
    }

    @objc private func shortcutJumpLinesDown() {
        moveCaretByLines(5)
    }

    @objc private func shortcutLineStart() {
        guard isEditMode || textView.isFirstResponder else { return }
        let ns = (textView.text ?? "") as NSString
        let loc = min(textView.selectedRange.location, ns.length)
        let line = ns.lineRange(for: NSRange(location: loc, length: 0))
        let content = CodeEditorIndent.contentBounds(inLine: line, of: ns)
        textView.selectedRange = NSRange(location: content.location, length: 0)
        textView.scrollRangeToVisible(NSRange(location: content.location, length: 0))
    }

    @objc private func shortcutLineEnd() {
        guard isEditMode || textView.isFirstResponder else { return }
        let ns = (textView.text ?? "") as NSString
        let loc = min(textView.selectedRange.location, ns.length)
        let line = ns.lineRange(for: NSRange(location: loc, length: 0))
        let content = CodeEditorIndent.contentBounds(inLine: line, of: ns)
        let end = NSMaxRange(content)
        textView.selectedRange = NSRange(location: end, length: 0)
        textView.scrollRangeToVisible(NSRange(location: end, length: 0))
    }

    @objc private func shortcutFontLarger() {
        bumpFontSize(by: 1)
    }

    @objc private func shortcutFontSmaller() {
        bumpFontSize(by: -1)
    }

    @objc private func shortcutToggleEditMode() {
        toggleEditModeFromKeyboardShortcut()
    }

    private func moveCaretByLines(_ delta: Int) {
        guard isEditMode || textView.isFirstResponder else { return }
        let ns = (textView.text ?? "") as NSString
        guard ns.length > 0 else { return }
        var loc = min(textView.selectedRange.location, ns.length)
        let step = delta > 0 ? 1 : -1
        let count = abs(delta)
        for _ in 0..<count {
            let line = ns.lineRange(for: NSRange(location: loc, length: 0))
            if step > 0 {
                let next = NSMaxRange(line)
                if next >= ns.length {
                    loc = ns.length
                    break
                }
                loc = next
            } else {
                if line.location == 0 {
                    loc = 0
                    break
                }
                loc = line.location - 1
                let prev = ns.lineRange(for: NSRange(location: loc, length: 0))
                loc = prev.location
            }
        }
        textView.selectedRange = NSRange(location: loc, length: 0)
        textView.scrollRangeToVisible(NSRange(location: loc, length: 0))
    }

    // MARK: - AI edit / Diff / Tab

    func aiEditSnapshot() -> (text: String, selectedRange: NSRange) {
        // While Diff is open the textView shows interleaved -/+/context — never use that
        // as a compose baseline (agent re-edits would look like a wall of +++++).
        let text: String
        if readSurface == .diff || readSurface == .diffPreview,
           let before = diffBeforeSnapshot {
            text = before
        } else {
            text = textView.text ?? ""
        }
        var range = textView.selectedRange
        if let pinned = askPinnedRange, pinned.length > 0 {
            range = pinned
        }
        return (text, range)
    }

    /// Baseline locked when the current Diff session opened (nil when not reviewing).
    var diffSessionBaseline: String? { diffBeforeSnapshot }

    /// Latest proposed text for the open Diff session.
    var diffSessionProposed: String? { diffAfterSnapshot }

    func applyAIEdit(range: NSRange, replacement: String) {
        let before = textView.text ?? ""
        let ns = before as NSString
        let safe = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        let after = ns.replacingCharacters(in: safe, with: replacement)
        applyResolvedDiffText(after)
    }

    /// Document currently loaded in the editor (nil when empty).
    var activeDocumentID: String? { currentDocumentID }

    /// Replace buffer + disk after「重跑」rollback (cancels any open Diff).
    func restoreDocumentText(_ text: String) {
        cancelDiffReviewForExternalMutation()
        applyResolvedDiffText(text)
        flushSaveIfNeeded(force: true)
        applyEditMode(false)
        refreshModeChrome()
        syncSurfaceVisibility()
    }

    func applyResolvedDiffText(_ text: String) {
        readSurface = .plain
        syncDiffChrome(show: false)
        applyHighlightedText(text)
        updateLineNumbers(force: true)
        isDirty = true
        updateProgressLabel()
        scheduleAutosave()
        onContentEdited?()
        if let conv = conversationIDForDirty {
            StudyFileContextStore.shared.markDirty(conversationID: conv)
        }
    }

    @discardableResult
    func presentInlineDiff(before: String, after: String) -> Bool {
        clearGhostSuggestion()
        textView.resignFirstResponder()
        isEditMode = false
        textView.isEditable = false
        readSurface = .diff
        diffBeforeSnapshot = before
        diffAfterSnapshot = after
        diffPresentGeneration &+= 1
        let gen = diffPresentGeneration

        // Heavy LCS/Myers off the main thread for large files; tiny edits stay sync
        // so unit tests (and snappy small patches) still apply immediately.
        let heavy = before.utf16.count + after.utf16.count > 24_000
        let apply: ([CodeDiffSegment]) -> Bool = { [weak self] segments in
            guard let self = self, gen == self.diffPresentGeneration else { return false }
            self.diffSegments = segments
            let pending = CodeTextDiff.pendingHunkIndices(in: segments)
            self.diffCurrentPendingIndex = 0
            if pending.isEmpty {
                self.spinner.stopAnimating()
                self.dismissInlineDiff(accept: false)
                return false
            }
            self.reloadDiffRendering()
            self.syncDiffChrome(show: true)
            self.refreshModeChrome()
            self.refreshTabToggleChrome()
            self.updateProgressLabel()
            self.syncSurfaceVisibility()
            self.notifyDiffSessionChange()
            self.spinner.stopAnimating()
            // Gutter ensureLayout + hunk bar placement are expensive — next turn
            // so the highlighted diff paints first without a hitch.
            DispatchQueue.main.async { [weak self] in
                guard let self = self, gen == self.diffPresentGeneration, self.readSurface == .diff else { return }
                self.updateLineNumbers(force: true, allowImmediateLayout: false)
                self.positionDiffHunkBar(animatedScroll: false)
            }
            return true
        }

        if heavy {
            spinner.startAnimating()
            DispatchQueue.global(qos: .userInitiated).async {
                let lines = CodeTextDiff.lines(before: before, after: after)
                let segments = CodeTextDiff.segments(from: lines)
                DispatchQueue.main.async {
                    _ = apply(segments)
                }
            }
            // Async path: caller already rejected identical text; treat as opened.
            return true
        }
        let lines = CodeTextDiff.lines(before: before, after: after)
        return apply(CodeTextDiff.segments(from: lines))
    }

    func dismissInlineDiff(accept: Bool) {
        // Capture before mutating — empty present / cancel must still clear the coordinator.
        let wasDiffSurface = readSurface == .diff || readSurface == .diffPreview
        let finished = onDiffFinished
        onDiffFinished = nil
        onDiffDecision = nil

        diffPresentGeneration &+= 1
        spinner.stopAnimating()
        if !accept, let before = diffBeforeSnapshot {
            applyHighlightedText(before)
            updateLineNumbers(force: true)
        }
        diffBeforeSnapshot = nil
        diffAfterSnapshot = nil
        diffSegments = []
        diffHunkRanges = [:]
        diffHunkDocY = [:]
        diffChromeZOrdered = false
        readSurface = .plain
        syncDiffChrome(show: false)
        textView.isEditable = isEditMode
        refreshModeChrome()
        refreshTabToggleChrome()
        updateProgressLabel()
        syncSurfaceVisibility()
        notifyDiffSessionChange()
        // Notify only when leaving a Diff surface. Avoids double-finish if already plain.
        if wasDiffSurface {
            finished?(nil)
        }
    }

    func diffKeepAll() {
        guard isDiffSessionActive else { return }
        for i in diffSegments.indices {
            guard case .hunk(var hunk) = diffSegments[i], hunk.decision == .pending else { continue }
            hunk.decision = .kept
            diffSegments[i] = .hunk(hunk)
        }
        finishDiffSession()
    }

    func diffUndoAll() {
        guard isDiffSessionActive else { return }
        for i in diffSegments.indices {
            guard case .hunk(var hunk) = diffSegments[i], hunk.decision == .pending else { continue }
            hunk.decision = .undone
            diffSegments[i] = .hunk(hunk)
        }
        finishDiffSession()
    }

    /// Scroll the current pending hunk into the editor viewport.
    func focusCurrentDiffHunk() {
        if readSurface == .diffPreview {
            enterDiffHunkSurface()
        }
        guard readSurface == .diff else { return }
        positionDiffHunkBar(animatedScroll: true)
    }

    var diffPendingHunkCount: Int {
        CodeTextDiff.pendingHunkIndices(in: diffSegments).count
    }

    /// Abort Diff review when the document is replaced / cleared externally.
    /// Restores `before` text, unlocks mode toggle, notifies coordinator + banner.
    func cancelDiffReviewForExternalMutation() {
        guard readSurface == .diff || readSurface == .diffPreview else { return }
        // dismissInlineDiff notifies onDiffFinished so the coordinator banner clears.
        dismissInlineDiff(accept: false)
    }

    /// After Keep: stay in reading mode (no keyboard). User can tap mode to edit.
    func enterReadingModeAfterKeep() {
        readSurface = .plain
        syncDiffChrome(show: false)
        applyEditMode(false)
        if textView.isFirstResponder {
            textView.resignFirstResponder()
        }
        refreshModeChrome()
        refreshTabToggleChrome()
        updateProgressLabel()
        syncSurfaceVisibility()
    }

    private func reloadDiffRendering() {
        let pending = CodeTextDiff.pendingHunkIndices(in: diffSegments)
        let highlight: Int? = {
            guard !pending.isEmpty else { return nil }
            let idx = min(diffCurrentPendingIndex, pending.count - 1)
            return pending[idx]
        }()
        let font = CodeSyntaxHighlighter.font(size: fontPointSize)
        let (attr, ranges) = CodeTextDiff.attributedString(
            segments: diffSegments,
            font: font,
            textColor: DSTheme.reader.textPrimary,
            highlightHunkIndex: highlight
        )
        diffHunkRanges = ranges
        textView.textStorage.setAttributedString(attr)
        updateDiffNavLabel()
        // Glyph metrics needed before anchoring per-hunk chips.
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        rebuildDiffHunkDocYCache()
        rebuildPerHunkActionBars()
        ensureDiffChromeZOrder()
    }

    /// Cache hunk vertical extents in **content** space (layoutManager + textContainerInset).
    private func rebuildDiffHunkDocYCache() {
        diffHunkDocY = [:]
        guard readSurface == .diff else { return }
        let pending = CodeTextDiff.pendingHunkIndices(in: diffSegments)
        let lm = textView.layoutManager
        let tc = textView.textContainer
        let insetTop = textView.textContainerInset.top
        let textLen = (textView.text as NSString?)?.length ?? 0
        for segIdx in pending {
            guard var range = diffHunkRanges[segIdx], range.length > 0 else { continue }
            if range.location >= textLen { continue }
            range.length = min(range.length, textLen - range.location)
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }
            let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            guard rect.height.isFinite, rect.width.isFinite else { continue }
            // Container coords → document content Y (stable across scroll).
            diffHunkDocY[segIdx] = (
                minY: rect.minY + insetTop,
                maxY: rect.maxY + insetTop
            )
        }
    }

    private func ensureDiffChromeZOrder() {
        guard readSurface == .diff else {
            diffChromeZOrdered = false
            return
        }
        for bar in diffPerHunkBars {
            textView.bringSubviewToFront(bar)
        }
        view.bringSubviewToFront(topBar)
        view.bringSubviewToFront(topBarSeparator)
        liftTopChrome()
        diffChromeZOrdered = true
    }

    private func updateDiffNavLabel() {
        let pending = CodeTextDiff.pendingHunkIndices(in: diffSegments)
        let text: String
        if pending.isEmpty {
            text = "—"
        } else {
            let i = min(diffCurrentPendingIndex, pending.count - 1) + 1
            text = "\(i)/\(pending.count)"
        }
        diffNavLabel.text = text
        let c = DSTheme.reader
        diffPrevButton.tintColor = c.textSecondary
        diffNextButton.tintColor = c.textSecondary
        diffNavLabel.textColor = c.textPrimary
        // Each bar shows its own ordinal (1-based) / total — always visible, not only when focused.
        for bar in diffPerHunkBars {
            if let label = bar.viewWithTag(9102) as? UILabel {
                if let ord = pending.firstIndex(of: bar.tag) {
                    label.text = "\(ord + 1)/\(pending.count)"
                } else {
                    label.text = "—"
                }
                label.textColor = c.textPrimary
            }
            if let prev = bar.viewWithTag(9101) as? UIButton {
                prev.tintColor = c.textSecondary
                prev.setTitleColor(c.textSecondary, for: .normal)
            }
            if let next = bar.viewWithTag(9103) as? UIButton {
                next.tintColor = c.textSecondary
                next.setTitleColor(c.textSecondary, for: .normal)
            }
        }
    }

    private func focusedPendingSegmentIndex() -> Int? {
        let pending = CodeTextDiff.pendingHunkIndices(in: diffSegments)
        guard !pending.isEmpty else { return nil }
        return pending[min(diffCurrentPendingIndex, pending.count - 1)]
    }

    private func notifyDiffSessionChange() {
        let active = isDiffSessionActive
        let count = CodeTextDiff.pendingHunkIndices(in: diffSegments).count
        onDiffSessionChange?(active, count)
    }

    private func clearPerHunkActionBars() {
        diffPerHunkBars.forEach { $0.removeFromSuperview() }
        diffPerHunkBars.removeAll()
    }

    /// Undo/Keep chips hosted on `textView` in content coordinates (scroll with hunks).
    private func rebuildPerHunkActionBars() {
        clearPerHunkActionBars()
        guard readSurface == .diff else { return }
        let pending = CodeTextDiff.pendingHunkIndices(in: diffSegments)
        guard !pending.isEmpty else { return }

        rebuildDiffHunkDocYCache()
        for segIdx in pending {
            let bar = makePerHunkActionBar(segIdx: segIdx)
            textView.addSubview(bar)
            diffPerHunkBars.append(bar)
        }
        layoutPerHunkActionBarsInContent()
        ensureDiffChromeZOrder()
    }

    /// Place chips in **textView content space** at hunk end. Y scrolls with UITextView; only X tracks trailing edge.
    private func layoutPerHunkActionBarsInContent() {
        guard readSurface == .diff, !diffPerHunkBars.isEmpty else { return }
        if diffHunkDocY.count < diffPerHunkBars.count {
            rebuildDiffHunkDocYCache()
        }
        let barH: CGFloat = 34
        let barW: CGFloat = 228 // ▲ n/N ▼ + Undo + Keep — always shown
        let trailingPad: CGFloat = 10
        let contentOffsetX = textView.contentOffset.x
        let visibleWidth = textView.bounds.width

        for bar in diffPerHunkBars {
            let segIdx = bar.tag
            guard let doc = diffHunkDocY[segIdx] else {
                bar.isHidden = true
                continue
            }
            // Content coords: Y locked to hunk bottom; X follows visible trailing edge.
            let x = contentOffsetX + visibleWidth - barW - trailingPad
            let y = doc.maxY - barH * 0.5
            bar.frame = CGRect(x: x, y: y, width: barW, height: barH)
            // Hide when fully above/below the visible band (optional; subview still scrolls correctly).
            let visibleMin = textView.contentOffset.y - 80
            let visibleMax = textView.contentOffset.y + textView.bounds.height + 80
            bar.isHidden = doc.maxY < visibleMin || doc.minY > visibleMax
        }
    }

    /// Update `n/N` from viewport; avoid destroying bars every frame (causes scroll hitch / perceived drift).
    private func syncDiffIndexFromViewport() {
        guard readSurface == .diff else { return }
        let pending = CodeTextDiff.pendingHunkIndices(in: diffSegments)
        guard !pending.isEmpty else { return }

        let offsetY = textView.contentOffset.y
        let focusY = offsetY + textView.bounds.height * 0.35

        var bestPendingOrd = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (ord, segIdx) in pending.enumerated() {
            guard let doc = diffHunkDocY[segIdx] else { continue }
            let dist: CGFloat
            if focusY >= doc.minY, focusY <= doc.maxY {
                dist = 0
            } else {
                dist = min(abs(focusY - doc.minY), abs(focusY - doc.maxY))
            }
            if dist < bestDist {
                bestDist = dist
                bestPendingOrd = ord
            }
        }
        guard bestPendingOrd != diffCurrentPendingIndex else { return }
        diffCurrentPendingIndex = bestPendingOrd
        // n/N is per-hunk and always on the bar — no rebuild needed on focus change.

        let dragging = textView.isDragging || textView.isDecelerating
        guard !dragging else {
            updateDiffNavLabel()
            return
        }
        let now = CACurrentMediaTime()
        let dy = abs(offsetY - lastDiffSyncOffsetY)
        let shouldRefreshHighlight = dy >= 24 || (now - lastDiffSyncAt) >= 0.08
        if shouldRefreshHighlight {
            lastDiffSyncOffsetY = offsetY
            lastDiffSyncAt = now
            scheduleDiffFocusHighlightRefresh()
        } else {
            updateDiffNavLabel()
        }
    }

    private func scheduleDiffFocusHighlightRefresh() {
        diffFocusHighlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshDiffFocusHighlightOnly()
        }
        diffFocusHighlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    /// Repaint focus wash + `n/N` without rebuilding action bar views.
    private func refreshDiffFocusHighlightOnly() {
        guard readSurface == .diff else { return }
        let pending = CodeTextDiff.pendingHunkIndices(in: diffSegments)
        let highlight: Int? = {
            guard !pending.isEmpty else { return nil }
            return pending[min(diffCurrentPendingIndex, pending.count - 1)]
        }()
        let font = CodeSyntaxHighlighter.font(size: fontPointSize)
        let (attr, ranges) = CodeTextDiff.attributedString(
            segments: diffSegments,
            font: font,
            textColor: DSTheme.reader.textPrimary,
            highlightHunkIndex: highlight
        )
        diffHunkRanges = ranges
        textView.textStorage.setAttributedString(attr)
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        rebuildDiffHunkDocYCache()
        layoutPerHunkActionBarsInContent()
        updateDiffNavLabel()
    }

    private func makePerHunkActionBar(segIdx: Int) -> UIView {
        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = true
        bar.backgroundColor = DSTheme.reader.surface.withAlphaComponent(0.82)
        bar.layer.cornerRadius = 8
        bar.layer.borderWidth = 1 / UIScreen.main.scale
        bar.layer.borderColor = DSTheme.reader.border.withAlphaComponent(0.55).cgColor
        bar.clipsToBounds = true
        bar.tag = segIdx

        let c = DSTheme.reader
        var leading: NSLayoutXAxisAnchor = bar.leadingAnchor
        var leadingConstant: CGFloat = 5

        // Always show ▲ n/N ▼ (this hunk's ordinal) — not only when scrolled into focus.
        let prev = UIButton(type: .system)
        prev.translatesAutoresizingMaskIntoConstraints = false
        prev.setTitle("▲", for: .normal)
        prev.titleLabel?.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        prev.setTitleColor(c.textSecondary, for: .normal)
        prev.tag = 9101
        prev.addTarget(self, action: #selector(diffPrevHunk), for: .touchUpInside)

        let nav = UILabel()
        nav.translatesAutoresizingMaskIntoConstraints = false
        nav.font = UIFont.systemFont(ofSize: 11, weight: .medium)
        nav.textAlignment = .center
        nav.textColor = c.textPrimary
        nav.tag = 9102
        let pending = CodeTextDiff.pendingHunkIndices(in: diffSegments)
        if let ord = pending.firstIndex(of: segIdx) {
            nav.text = "\(ord + 1)/\(pending.count)"
        } else {
            nav.text = "—"
        }

        let next = UIButton(type: .system)
        next.translatesAutoresizingMaskIntoConstraints = false
        next.setTitle("▼", for: .normal)
        next.titleLabel?.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        next.setTitleColor(c.textSecondary, for: .normal)
        next.tag = 9103
        next.addTarget(self, action: #selector(diffNextHunk), for: .touchUpInside)

        bar.addSubview(prev)
        bar.addSubview(nav)
        bar.addSubview(next)
        NSLayoutConstraint.activate([
            prev.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 4),
            prev.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            prev.widthAnchor.constraint(equalToConstant: 24),
            prev.heightAnchor.constraint(equalToConstant: 26),
            nav.leadingAnchor.constraint(equalTo: prev.trailingAnchor, constant: 0),
            nav.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            nav.widthAnchor.constraint(equalToConstant: 36),
            next.leadingAnchor.constraint(equalTo: nav.trailingAnchor, constant: 0),
            next.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            next.widthAnchor.constraint(equalToConstant: 24),
            next.heightAnchor.constraint(equalToConstant: 26)
        ])
        leading = next.trailingAnchor
        leadingConstant = 6

        let undo = UIButton(type: .system)
        undo.translatesAutoresizingMaskIntoConstraints = false
        undo.setTitle("撤销", for: .normal)
        undo.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        undo.backgroundColor = UIColor(red: 0.75, green: 0.18, blue: 0.18, alpha: 0.88)
        undo.setTitleColor(.white, for: .normal)
        undo.layer.cornerRadius = 6
        undo.tag = segIdx
        undo.addTarget(self, action: #selector(diffUndoHunkAtButton(_:)), for: .touchUpInside)

        let keep = UIButton(type: .system)
        keep.translatesAutoresizingMaskIntoConstraints = false
        keep.setTitle("保留", for: .normal)
        keep.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        keep.backgroundColor = UIColor(red: 0.10, green: 0.55, blue: 0.28, alpha: 0.88)
        keep.setTitleColor(.white, for: .normal)
        keep.layer.cornerRadius = 6
        keep.tag = segIdx
        keep.addTarget(self, action: #selector(diffKeepHunkAtButton(_:)), for: .touchUpInside)

        bar.addSubview(undo)
        bar.addSubview(keep)
        // Fixed equal widths — Chinese labels stay visually even.
        let btnW: CGFloat = 56
        NSLayoutConstraint.activate([
            undo.leadingAnchor.constraint(equalTo: leading, constant: leadingConstant),
            undo.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            undo.heightAnchor.constraint(equalToConstant: 26),
            undo.widthAnchor.constraint(equalToConstant: btnW),
            keep.leadingAnchor.constraint(equalTo: undo.trailingAnchor, constant: 5),
            keep.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -5),
            keep.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            keep.heightAnchor.constraint(equalToConstant: 26),
            keep.widthAnchor.constraint(equalToConstant: btnW)
        ])
        return bar
    }

    /// Scroll focus hunk into view; rebuild chips. Corner floating nav stays hidden.
    private func positionDiffHunkBar(animatedScroll: Bool = false) {
        guard readSurface == .diff else {
            diffHunkBar.isHidden = true
            clearPerHunkActionBars()
            return
        }
        let pending = CodeTextDiff.pendingHunkIndices(in: diffSegments)
        guard !pending.isEmpty else {
            diffHunkBar.isHidden = true
            clearPerHunkActionBars()
            return
        }
        let hunkIdx = pending[min(diffCurrentPendingIndex, pending.count - 1)]
        if let range = diffHunkRanges[hunkIdx] {
            scrollDiffHunkIntoView(range, animated: animatedScroll)
        }

        let place: () -> Void = { [weak self] in
            guard let self = self, self.readSurface == .diff else { return }
            self.textView.layoutManager.ensureLayout(for: self.textView.textContainer)
            self.rebuildPerHunkActionBars()
            self.placeDiffNavChrome()
        }

        if animatedScroll {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: place)
        } else {
            place()
        }
    }

    /// Corner floating nav removed — n/N lives on every hunk bar.
    private func placeDiffNavChrome() {
        diffHunkBar.isHidden = true
        updateDiffNavLabel()
    }

    private func scrollDiffHunkIntoView(_ range: NSRange, animated: Bool) {
        let ns = (textView.text ?? "") as NSString
        let safeLoc = max(0, min(range.location, ns.length))
        let safeLen = max(1, min(range.length, ns.length - safeLoc))
        let safe = NSRange(location: safeLoc, length: safeLen)

        guard let start = textView.position(from: textView.beginningOfDocument, offset: safe.location),
              let end = textView.position(from: start, offset: min(safe.length, 1)) else {
            textView.scrollRangeToVisible(NSRange(location: safeLoc, length: 1))
            return
        }
        let caret = textView.caretRect(for: start)
        let visibleH = max(1, textView.bounds.height - textView.contentInset.top - textView.contentInset.bottom)
        let targetY = caret.midY - visibleH * 0.28
        let maxOffset = max(
            0,
            textView.contentSize.height - textView.bounds.height + textView.contentInset.bottom
        )
        let offset = CGPoint(x: 0, y: min(max(0, targetY - textView.contentInset.top), maxOffset))
        if abs(offset.y - textView.contentOffset.y) > 2 {
            textView.setContentOffset(offset, animated: animated)
        } else {
            _ = end
            textView.scrollRangeToVisible(safe)
        }
    }

    private func syncDiffChrome(show: Bool) {
        if !show {
            diffHunkBar.isHidden = true
            clearPerHunkActionBars()
            diffChromeZOrdered = false
        }
        textBottomToView.isActive = true
        gutterBottomToView.isActive = true
        gutterSepBottomToView.isActive = true
        view.layoutIfNeeded()
        if show {
            positionDiffHunkBar(animatedScroll: false)
            ensureDiffChromeZOrder()
        }
    }

    private func decideCurrentHunk(keep: Bool) {
        let pending = CodeTextDiff.pendingHunkIndices(in: diffSegments)
        guard !pending.isEmpty else { return }
        let cursor = min(diffCurrentPendingIndex, pending.count - 1)
        decideHunk(segIdx: pending[cursor], keep: keep)
    }

    private func decideHunk(segIdx: Int, keep: Bool) {
        guard segIdx >= 0, segIdx < diffSegments.count,
              case .hunk(var hunk) = diffSegments[segIdx],
              hunk.decision == .pending else { return }
        // Cancel deferred focus-wash so a kept hunk never briefly keeps the blue overlay.
        diffFocusHighlightWork?.cancel()
        diffFocusHighlightWork = nil
        hunk.decision = keep ? .kept : .undone
        diffSegments[segIdx] = .hunk(hunk)
        let pending = CodeTextDiff.pendingHunkIndices(in: diffSegments)
        notifyDiffSessionChange()
        if pending.isEmpty {
            finishDiffSession()
            return
        }
        // Prefer the next pending after the one just decided.
        if let next = pending.first(where: { $0 > segIdx }) {
            diffCurrentPendingIndex = pending.firstIndex(of: next) ?? 0
        } else {
            diffCurrentPendingIndex = min(diffCurrentPendingIndex, pending.count - 1)
        }
        reloadDiffRendering()
        rebuildDiffHunkDocYCache()
        layoutPerHunkActionBarsInContent()
        // Do not auto-scroll after Keep/Undo — keeps the decided hunk in view for visual QA
        // and avoids yanking the viewport under the user's finger.
        updateDiffNavLabel()
        refreshDiffFocusHighlightOnly()
    }

    private func finishDiffSession() {
        let before = diffBeforeSnapshot ?? ""
        let final = CodeTextDiff.compose(diffSegments, pendingAsUndone: true)
        let anyKept = diffSegments.contains { seg in
            if case .hunk(let h) = seg, h.decision == .kept { return true }
            return false
        }
        diffFocusHighlightWork?.cancel()
        diffFocusHighlightWork = nil
        diffBeforeSnapshot = nil
        diffAfterSnapshot = nil
        diffSegments = []
        diffHunkRanges = [:]
        diffHunkDocY = [:]
        diffChromeZOrdered = false
        readSurface = .plain
        syncDiffChrome(show: false)
        notifyDiffSessionChange()
        let finished = onDiffFinished
        let decision = onDiffDecision
        onDiffFinished = nil
        onDiffDecision = nil
        if let finished {
            if anyKept {
                // Coordinator applies final text + stays in reading mode.
                finished(final)
            } else {
                applyHighlightedText(before)
                updateLineNumbers(force: true)
                textView.isEditable = isEditMode
                refreshModeChrome()
                refreshTabToggleChrome()
                updateProgressLabel()
                finished(nil)
            }
        } else if anyKept {
            applyResolvedDiffText(final)
            enterReadingModeAfterKeep()
            decision?(true)
        } else {
            applyHighlightedText(before)
            updateLineNumbers(force: true)
            textView.isEditable = isEditMode
            refreshModeChrome()
            refreshTabToggleChrome()
            updateProgressLabel()
            decision?(false)
        }
    }

    @objc private func diffPrevHunk() {
        let pending = CodeTextDiff.pendingHunkIndices(in: diffSegments)
        guard !pending.isEmpty else { return }
        diffCurrentPendingIndex = (diffCurrentPendingIndex - 1 + pending.count) % pending.count
        reloadDiffRendering()
        positionDiffHunkBar(animatedScroll: true)
    }

    @objc private func diffNextHunk() {
        let pending = CodeTextDiff.pendingHunkIndices(in: diffSegments)
        guard !pending.isEmpty else { return }
        diffCurrentPendingIndex = (diffCurrentPendingIndex + 1) % pending.count
        reloadDiffRendering()
        positionDiffHunkBar(animatedScroll: true)
    }

    @objc private func diffUndoHunk() {
        decideCurrentHunk(keep: false)
    }

    @objc private func diffKeepHunk() {
        decideCurrentHunk(keep: true)
    }

    @objc private func diffUndoHunkAtButton(_ sender: UIButton) {
        decideHunk(segIdx: sender.tag, keep: false)
    }

    @objc private func diffKeepHunkAtButton(_ sender: UIButton) {
        decideHunk(segIdx: sender.tag, keep: true)
    }

    private func refreshTabToggleChrome() {
        let c = DSTheme.reader
        // Diff hunk chrome still refreshes here (shared theme pass).
        tabConfirmButton.setTitleColor(c.accent, for: .normal)
        tabDismissButton.setTitleColor(c.textSecondary, for: .normal)
        tabSuggestChip.backgroundColor = c.surface
        tabSuggestChip.layer.borderColor = c.border.cgColor
        diffHunkBar.backgroundColor = c.surface.withAlphaComponent(0.78)
        diffHunkBar.layer.borderColor = c.border.withAlphaComponent(0.55).cgColor

        guard CodeEditorFeatureFlags.tabCompletionEnabled else {
            tabToggleButton.isHidden = true
            tabToggleButton.isEnabled = false
            tabToggleWidthConstraint.constant = 0
            clearGhostSuggestion()
            return
        }

        let usable = isEditMode && !isDiffSessionActive
        let on = tabCompletionEnabled && usable
        tabToggleButton.isHidden = false
        tabToggleWidthConstraint.constant = 40
        tabToggleButton.alpha = usable ? 1 : 0.35
        tabToggleButton.isEnabled = usable
        tabToggleButton.setTitleColor(on ? c.accent : c.textSecondary, for: .normal)
        tabToggleButton.backgroundColor = on ? c.accent.withAlphaComponent(0.14) : .clear
        tabToggleButton.layer.cornerRadius = 8
        tabToggleButton.accessibilityValue = tabCompletionEnabled ? "开" : "关"
        tabToggleButton.accessibilityHint = "仅开关补全；接受请用光标旁 Accept"
    }

    @objc private func tabToggleTapped() {
        guard CodeEditorFeatureFlags.tabCompletionEnabled else { return }
        tabCompletionEnabled.toggle()
        UserDefaults.standard.set(tabCompletionEnabled, forKey: "connects.codeEditor.tabCompletion")
        refreshTabToggleChrome()
        if !tabCompletionEnabled { clearGhostSuggestion() }
    }

    private func clearGhostSuggestion() {
        ghostSuggestion = nil
        tabSuggestLabel.text = nil
        tabSuggestChip.isHidden = true
        tabCompleteWorkItem?.cancel()
    }

    @objc private func acceptGhostTapped() {
        acceptGhostSuggestion()
    }

    @objc private func dismissGhostTapped() {
        clearGhostSuggestion()
    }

    private func acceptGhostSuggestion() {
        guard let ghost = ghostSuggestion, !ghost.isEmpty, isEditMode else { return }
        let range = textView.selectedRange
        let attrs = CodeSyntaxHighlighter.typingAttributes(fontSize: fontPointSize)
        let attributed = NSAttributedString(string: ghost, attributes: attrs)
        textView.textStorage.beginEditing()
        textView.textStorage.replaceCharacters(in: range, with: attributed)
        textView.textStorage.endEditing()
        textView.selectedRange = NSRange(location: range.location + (ghost as NSString).length, length: 0)
        clearGhostSuggestion()
        textViewDidChange(textView)
    }

    private func scheduleTabCompletion() {
        guard CodeEditorFeatureFlags.tabCompletionEnabled,
              tabCompletionEnabled, isEditMode, !isDiffSessionActive else { return }
        tabCompleteWorkItem?.cancel()
        tabCompleteGeneration &+= 1
        let gen = tabCompleteGeneration
        let work = DispatchWorkItem { [weak self] in
            self?.requestTabCompletion(generation: gen)
        }
        tabCompleteWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    private func requestTabCompletion(generation: UInt) {
        guard generation == tabCompleteGeneration,
              tabCompletionEnabled,
              isEditMode,
              !isDiffSessionActive,
              let provider = completionProvider else { return }
        let text = textView.text ?? ""
        let loc = textView.selectedRange.location
        let ns = text as NSString
        let lineRange = ns.lineRange(for: NSRange(location: min(loc, ns.length), length: 0))
        let lineContext = ns.substring(with: lineRange)
        let prefix = ns.substring(with: NSRange(location: lineRange.location,
                                                length: max(0, min(loc, ns.length) - lineRange.location)))
        let caretPrefix = ns.substring(to: min(loc, ns.length))
        let fileName: String = {
            if let id = currentDocumentID,
               let doc = StudyDocumentStore.shared.document(id: id) {
                return doc.title
            }
            return "untitled.\(language.preferredFileExtension)"
        }()
        provider.requestCompletions(
            fileName: fileName,
            language: language.rawValue,
            caretPrefix: String(caretPrefix.suffix(6_000)),
            fullText: String(text.prefix(12_000)),
            lineContext: lineContext,
            linePrefix: prefix
        ) { [weak self] suggestions in
            DispatchQueue.main.async {
                guard let self = self,
                      generation == self.tabCompleteGeneration,
                      let first = suggestions.first, !first.isEmpty else { return }
                self.showGhostSuggestion(first)
            }
        }
    }

    private func showGhostSuggestion(_ text: String) {
        // Cap display — avoid dumping huge blobs that look like “double code”.
        let capped = text.count > 240 ? String(text.prefix(240)) + "…" : text
        ghostSuggestion = text
        tabSuggestLabel.font = CodeSyntaxHighlighter.font(size: max(11, fontPointSize - 1))
        tabSuggestLabel.text = capped.replacingOccurrences(of: "\n", with: " ⏎ ")
        tabSuggestChip.isHidden = false
        view.bringSubviewToFront(tabSuggestChip)
        repositionTabSuggestChip(scrollCaretFirst: true)
    }

    /// Place the Tab accept chip under the caret (trailing when room allows).
    private func repositionTabSuggestChip(scrollCaretFirst: Bool = false) {
        guard !tabSuggestChip.isHidden, ghostSuggestion != nil else { return }
        let caretRange = textView.selectedRange
        if scrollCaretFirst {
            textView.scrollRangeToVisible(NSRange(location: caretRange.location, length: max(1, caretRange.length)))
            view.layoutIfNeeded()
        }

        let chipH: CGFloat = 40
        let maxChipW = min(320, max(160, textView.bounds.width - 24))
        tabSuggestChip.bounds = CGRect(x: 0, y: 0, width: maxChipW, height: chipH)
        tabSuggestChip.setNeedsLayout()
        tabSuggestChip.layoutIfNeeded()
        let fitted = tabSuggestChip.systemLayoutSizeFitting(
            CGSize(width: maxChipW, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .required
        )
        let chipW = min(maxChipW, max(140, ceil(fitted.width)))
        let chipSize = CGSize(width: chipW, height: max(chipH, ceil(fitted.height)))

        var visible = textView.convert(textView.bounds, to: view).intersection(view.bounds)
        if visible.isNull {
            visible = textView.frame.intersection(view.bounds)
        }
        // Keep above soft-keyboard inset inside the text view.
        let kbPad = keyboardBottomInset
        if kbPad > 0 {
            visible = CGRect(
                x: visible.minX,
                y: visible.minY,
                width: visible.width,
                height: max(chipSize.height + 8, visible.height - kbPad)
            )
        }

        let nsLen = (textView.text as NSString?)?.length ?? 0
        let loc = min(max(0, caretRange.location), nsLen)
        guard let caretPos = textView.position(from: textView.beginningOfDocument, offset: loc) else {
            tabSuggestChip.frame = CGRect(
                x: visible.minX + 8,
                y: min(visible.maxY - chipSize.height - 4, visible.minY + 8),
                width: chipSize.width,
                height: chipSize.height
            )
            return
        }
        let caret = textView.convert(textView.caretRect(for: caretPos), to: view)

        // Prefer under the caret line; if that clips, try same-line trailing, else above.
        let yBelow = caret.maxY + 4
        let yAbove = caret.minY - chipSize.height - 4
        let ySame = caret.minY + (caret.height - chipSize.height) * 0.5
        let trailingX = caret.maxX + 8
        let leadingX = visible.minX + 8

        var origin: CGPoint
        if yBelow + chipSize.height <= visible.maxY - 4 {
            // Under caret; start near caret x, clamp into visible.
            origin = CGPoint(
                x: min(max(leadingX, caret.minX), visible.maxX - chipSize.width - 8),
                y: yBelow
            )
        } else if trailingX + chipSize.width <= visible.maxX - 8,
                  ySame >= visible.minY + 4,
                  ySame + chipSize.height <= visible.maxY - 4 {
            origin = CGPoint(x: trailingX, y: ySame)
        } else if yAbove >= visible.minY + 4 {
            origin = CGPoint(
                x: min(max(leadingX, caret.minX), visible.maxX - chipSize.width - 8),
                y: yAbove
            )
        } else {
            origin = CGPoint(
                x: min(max(leadingX, caret.minX), visible.maxX - chipSize.width - 8),
                y: min(max(visible.minY + 4, yBelow), visible.maxY - chipSize.height - 4)
            )
        }
        origin.x = min(max(visible.minX + 8, origin.x), max(visible.minX + 8, visible.maxX - chipSize.width - 8))
        origin.y = min(max(visible.minY + 4, origin.y), max(visible.minY + 4, visible.maxY - chipSize.height - 4))
        tabSuggestChip.frame = CGRect(origin: origin, size: chipSize)
        view.bringSubviewToFront(tabSuggestChip)
    }

    /// Portrait Study / editor: reserved API — shell now raises the whole page above the
    /// keyboard, so inset cover is no longer used. Kept as a no-op reset for callers.
    func applyKeyboardBottomInset(_ inset: CGFloat) {
        keyboardBottomInset = 0
        var insets = textView.contentInset
        if insets.bottom != 0 {
            insets.bottom = 0
            textView.contentInset = insets
            textView.verticalScrollIndicatorInsets = insets
            textView.horizontalScrollIndicatorInsets = insets
        }
        if !tabSuggestChip.isHidden {
            repositionTabSuggestChip()
        }
        _ = inset
    }

    func keyCommandsAcceptGhostOrPass() -> Bool {
        guard ghostSuggestion != nil else { return false }
        acceptGhostSuggestion()
        return true
    }
}

// MARK: - Markdown preview WKNavigationDelegate

extension TextCodeEditorViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === previewWebView else { return }
        previewShellLoaded = true
        previewWebView.scrollView.isScrollEnabled = true
        tryInjectPendingPreview()
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url {
            let href = url.absoluteString
            if MarkdownPreviewAssetIndex.isPreviewAssetHref(href)
                || MarkdownStudyImporter.isStudyAssetHref(href) {
                if navigationAction.navigationType == .linkActivated {
                    decisionHandler(.cancel)
                    presentPreviewAsset(href: href)
                    return
                }
                decisionHandler(.allow)
                return
            }
            if navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }
}

/// Paints logical line numbers at the editor’s TextKit fragment origins.
private final class CodeLineNumberGutterView: UIView {
    weak var sourceTextView: UITextView?
    var fontSize: CGFloat = CodeSyntaxHighlighter.defaultPointSize {
        didSet {
            if abs(oldValue - fontSize) > 0.05 { setNeedsDisplay() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        contentMode = .redraw
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isOpaque = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        contentMode = .redraw
        clipsToBounds = true
    }

    override func draw(_ rect: CGRect) {
        guard let tv = sourceTextView else { return }
        let layout = tv.layoutManager
        let container = tv.textContainer
        layout.ensureLayout(for: container)
        let inset = tv.textContainerInset
        let offsetY = tv.contentOffset.y
        let attrs = CodeSyntaxHighlighter.lineNumberAttributes(fontSize: fontSize)
        let ns = (tv.text ?? "") as NSString
        let visible = bounds.insetBy(dx: 0, dy: -fontSize)
        let labelWidth = max(8, bounds.width - 12)

        func drawNumber(_ number: Int, fragment: CGRect) {
            let y = fragment.minY + inset.top - offsetY
            let box = CGRect(x: 4, y: y, width: labelWidth, height: max(fragment.height, 1))
            guard box.maxY >= visible.minY, box.minY <= visible.maxY else { return }
            ("\(number)" as NSString).draw(
                with: box,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs,
                context: nil
            )
        }

        let glyphCount = layout.numberOfGlyphs
        if glyphCount == 0 {
            drawNumber(1, fragment: CGRect(x: 0, y: 0, width: 1, height: CodeSyntaxHighlighter.font(size: fontSize).lineHeight))
            return
        }

        var logicalLine = 1
        var glyphIndex = 0
        while glyphIndex < glyphCount {
            var fragmentRange = NSRange()
            let fragment = layout.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &fragmentRange)
            let charRange = layout.characterRange(forGlyphRange: fragmentRange, actualGlyphRange: nil)
            let isFirstFragment: Bool
            if charRange.location == 0 {
                isFirstFragment = true
            } else if charRange.location < ns.length {
                isFirstFragment = ns.character(at: charRange.location - 1) == 10
            } else {
                isFirstFragment = false
            }
            if isFirstFragment {
                drawNumber(logicalLine, fragment: fragment)
                logicalLine += 1
            }
            glyphIndex = NSMaxRange(fragmentRange)
        }

        let extra = layout.extraLineFragmentRect
        if extra.height > 0, ns.length > 0, ns.character(at: ns.length - 1) == 10 {
            drawNumber(logicalLine, fragment: extra)
        }
    }
}
