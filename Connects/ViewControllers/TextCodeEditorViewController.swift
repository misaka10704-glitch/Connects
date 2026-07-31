import UIKit
import WebKit

/// Study-mode code / plain-text editor with syntax highlighting.
final class TextCodeEditorViewController: UIViewController, UITextViewDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let topBar = UIView()
    private let topBarSeparator = UIView()
    private let sidebarButton = UIButton(type: .system)
    private let modeButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let progressLabel = UILabel()
    private let gutterView = UIView()
    private let gutterSeparator = UIView()
    /// Non-interactive twin of the editor; contentOffset stays locked to `textView`.
    private let lineNumberView = UITextView()
    private let textView = StudyAskTextView(fullLineBackgrounds: true)
    private let spinner = UIActivityIndicatorView(style: .medium)
    /// Markdown preview only (`language == .markdown`). Transitional WK shell — see markdown-render-engine rule.
    private var previewWebView: WKWebView!
    private var previewShellLoaded = false
    private var pendingPreviewMarkdown: String?

    private var currentDocumentID: String?
    private var language: StudyTextLanguage = .plain
    private var loadGeneration: UInt = 0
    private var sidebarButtonWidthConstraint: NSLayoutConstraint!
    private var gutterWidthConstraint: NSLayoutConstraint!
    private var isEditMode = false
    private var isDirty = false
    /// Reading sub-state. `diff` = hunk UI; `diffPreview` = all-kept plain preview (still in Diff session).
    private enum ReadSurface { case plain, diff, diffPreview }
    private var readSurface: ReadSurface = .plain
    private var tabCompletionEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "connects.codeEditor.tabCompletion") == nil { return true }
        return UserDefaults.standard.bool(forKey: "connects.codeEditor.tabCompletion")
    }()
    private var ghostSuggestion: String?
    private var tabCompleteWorkItem: DispatchWorkItem?
    private var tabCompleteGeneration: UInt = 0
    private let tabToggleButton = UIButton(type: .system)
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
    private var isSyncingLineNumbers = false
    private var readerSurfaceActive = true
    private var pendingViewportProgress: StudyProgress?
    private var conversationIDForDirty: String?

    // MARK: - AI edit / Tab / inline diff (CodeEditorAIBridge)
    // Implemented on this VC; coordinator drives Diff + Keep/Reject.

    private static let fontSizeDefaultsKey = "connects.codeEditor.fontSize"
    private static let minFontPointSize: CGFloat = 9
    private static let maxFontPointSize: CGFloat = 28
    private var fontPointSize: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: TextCodeEditorViewController.fontSizeDefaultsKey)
        if stored >= 9, stored <= 28 { return CGFloat(stored) }
        return CodeSyntaxHighlighter.defaultPointSize
    }()
    private var pinchBaseFontSize: CGFloat = CodeSyntaxHighlighter.defaultPointSize

    var onPageChanged: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onContentEdited: (() -> Void)?
    var onAskSelection: ((String) -> Void)?

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
        view.backgroundColor = DSTheme.c.background
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
        sidebarButtonWidthConstraint = sidebarButton.widthAnchor.constraint(equalToConstant: 40)

        modeButton.translatesAutoresizingMaskIntoConstraints = false
        modeButton.setImage(ActionIconFactory.image(.editMode, pointSize: 18), for: .normal)
        modeButton.imageView?.contentMode = .scaleAspectFit
        modeButton.addTarget(self, action: #selector(modeTapped), for: .touchUpInside)
        modeButton.accessibilityLabel = "切换到编辑模式"
        topBar.addSubview(modeButton)

        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.setImage(ActionIconFactory.image(.save, pointSize: 18), for: .normal)
        saveButton.imageView?.contentMode = .scaleAspectFit
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        saveButton.accessibilityLabel = "保存"
        topBar.addSubview(saveButton)

        tabToggleButton.translatesAutoresizingMaskIntoConstraints = false
        tabToggleButton.setTitle("Tab", for: .normal)
        tabToggleButton.titleLabel?.font = UIFont.systemFont(ofSize: 11, weight: .bold)
        tabToggleButton.addTarget(self, action: #selector(tabToggleTapped), for: .touchUpInside)
        tabToggleButton.accessibilityLabel = "Tab 补全"
        tabToggleButton.accessibilityHint = "关闭后编辑时不再出现灰字建议"
        topBar.addSubview(tabToggleButton)
        refreshTabToggleChrome()

        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        progressLabel.textColor = DSTheme.c.textSecondary
        progressLabel.textAlignment = .center
        progressLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        topBar.addSubview(progressLabel)

        gutterView.translatesAutoresizingMaskIntoConstraints = false
        gutterView.clipsToBounds = true
        view.addSubview(gutterView)

        lineNumberView.translatesAutoresizingMaskIntoConstraints = false
        lineNumberView.isEditable = false
        lineNumberView.isSelectable = false
        lineNumberView.isScrollEnabled = true
        lineNumberView.isUserInteractionEnabled = false
        lineNumberView.backgroundColor = .clear
        lineNumberView.textAlignment = .right
        lineNumberView.font = CodeSyntaxHighlighter.font(size: fontPointSize)
        lineNumberView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 8)
        lineNumberView.textContainer.lineFragmentPadding = 0
        lineNumberView.textContainer.widthTracksTextView = true
        lineNumberView.textContainer.lineBreakMode = .byClipping
        lineNumberView.showsVerticalScrollIndicator = false
        lineNumberView.showsHorizontalScrollIndicator = false
        if #available(iOS 11.0, *) {
            lineNumberView.contentInsetAdjustmentBehavior = .never
        }
        gutterView.addSubview(lineNumberView)

        gutterSeparator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(gutterSeparator)

        gutterWidthConstraint = gutterView.widthAnchor.constraint(equalToConstant: 44)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.delegate = self
        textView.backgroundColor = DSTheme.c.background
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
        view.addSubview(textView)

        // Caret-trailing Tab accept chip (frame-based; subviews use Auto Layout).
        tabSuggestChip.translatesAutoresizingMaskIntoConstraints = true
        tabSuggestChip.isHidden = true
        tabSuggestChip.backgroundColor = DSTheme.c.surface
        tabSuggestChip.layer.cornerRadius = 10
        tabSuggestChip.layer.borderWidth = 1 / UIScreen.main.scale
        tabSuggestChip.layer.borderColor = DSTheme.c.border.cgColor
        tabSuggestChip.clipsToBounds = true
        view.addSubview(tabSuggestChip)

        tabSuggestLabel.translatesAutoresizingMaskIntoConstraints = false
        tabSuggestLabel.font = CodeSyntaxHighlighter.font(size: fontPointSize)
        tabSuggestLabel.textColor = DSTheme.c.textTertiary
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
        previewWebView = WKWebView(frame: .zero, configuration: config)
        previewWebView.translatesAutoresizingMaskIntoConstraints = false
        ConnectsWebKit.applyReadingSurfaceTuning(previewWebView, background: DSTheme.c.background)
        previewWebView.isHidden = true
        previewWebView.navigationDelegate = self
        view.addSubview(previewWebView)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 40),

            sidebarButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 4),
            sidebarButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            sidebarButtonWidthConstraint,
            sidebarButton.heightAnchor.constraint(equalToConstant: 40),

            progressLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            progressLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            progressLabel.leadingAnchor.constraint(greaterThanOrEqualTo: sidebarButton.trailingAnchor, constant: 4),
            progressLabel.trailingAnchor.constraint(lessThanOrEqualTo: tabToggleButton.leadingAnchor, constant: -4),

            // Far-right chrome: [Tab][mode][save]
            saveButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -4),
            saveButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            saveButton.widthAnchor.constraint(equalToConstant: 40),
            saveButton.heightAnchor.constraint(equalToConstant: 40),

            modeButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -2),
            modeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            modeButton.widthAnchor.constraint(equalToConstant: 40),
            modeButton.heightAnchor.constraint(equalToConstant: 40),

            tabToggleButton.trailingAnchor.constraint(equalTo: modeButton.leadingAnchor, constant: -2),
            tabToggleButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            tabToggleButton.widthAnchor.constraint(equalToConstant: 40),
            tabToggleButton.heightAnchor.constraint(equalToConstant: 32),

            topBarSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBarSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBarSeparator.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            topBarSeparator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            gutterView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gutterView.topAnchor.constraint(equalTo: topBarSeparator.bottomAnchor),
            gutterWidthConstraint,

            lineNumberView.leadingAnchor.constraint(equalTo: gutterView.leadingAnchor),
            lineNumberView.trailingAnchor.constraint(equalTo: gutterView.trailingAnchor),
            lineNumberView.topAnchor.constraint(equalTo: gutterView.topAnchor),
            lineNumberView.bottomAnchor.constraint(equalTo: gutterView.bottomAnchor),

            gutterSeparator.leadingAnchor.constraint(equalTo: gutterView.trailingAnchor, constant: 6),
            gutterSeparator.topAnchor.constraint(equalTo: topBarSeparator.bottomAnchor),
            gutterSeparator.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            textView.leadingAnchor.constraint(equalTo: gutterSeparator.trailingAnchor, constant: 10),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.topAnchor.constraint(equalTo: topBarSeparator.bottomAnchor),

            previewWebView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewWebView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewWebView.topAnchor.constraint(equalTo: topBarSeparator.bottomAnchor),
            previewWebView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        textBottomToView = textView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        gutterBottomToView = gutterView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        gutterSepBottomToView = gutterSeparator.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        textBottomToView.isActive = true
        gutterBottomToView.isActive = true
        gutterSepBottomToView.isActive = true

        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeDidChange, object: nil)
        applyChromeColors()
        // Defaults already match read mode; avoid applyEditMode during load (view has no window yet).
        isEditMode = false
        textView.isEditable = false
        textView.isSelectable = true
        refreshModeChrome()
        updateProgressLabel()
        syncSurfaceVisibility()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = textView.bounds.width
        if abs(w - lastWrapLayoutWidth) > 0.5 {
            lastWrapLayoutWidth = w
            updateLineNumbers(force: true)
        }
        syncLineNumberOffset()
        if readSurface == .diff {
            layoutPerHunkActionBarsInContent()
            placeDiffNavChrome()
        }
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
        sidebarButton.setImage(ActionIconFactory.image(kind, pointSize: 18), for: .normal)
        sidebarButton.tintColor = DSTheme.c.textSecondary
        sidebarButton.accessibilityLabel = collapsed ? "打开侧栏" : "关闭侧栏"
    }

    func setSidebarButtonHidden(_ hidden: Bool) {
        sidebarButton.isHidden = hidden
        sidebarButtonWidthConstraint.constant = hidden ? 0 : 40
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
            let lang = StudyDocumentStore.shared.document(id: documentID)?.textLanguage ?? .plain
            DispatchQueue.main.async {
                guard self.loadGeneration == gen else { return }
                self.language = lang
                self.isDirty = false
                self.applyHighlightedText(text)
                self.updateLineNumbers(force: true)
                self.syncLineNumberOffset()
                self.updateProgressLabel()
                self.syncSurfaceVisibility()
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
        textView.text = ""
        lineNumberView.text = ""
        progressLabel.text = nil
        isDirty = false
        pendingPreviewMarkdown = nil
        previewWebView.evaluateJavaScript("window.__connectsRender && window.__connectsRender('');", completionHandler: nil)
        syncSurfaceVisibility()
    }

    func pauseReading() {
        flushSaveIfNeeded()
        textView.resignFirstResponder()
    }

    func prepareForShellLayoutChange() {}
    func beginShellRotation(keeping progress: StudyProgress?) {
        pendingViewportProgress = progress ?? captureReadingProgress()
    }
    func updateDuringShellRotation() {}
    func finishShellRotation(using progress: StudyProgress?) {
        realignVisibleViewport(using: progress ?? pendingViewportProgress)
        pendingViewportProgress = nil
    }
    func resumeAfterConversationSwitch() {
        syncLineNumberOffset()
    }

    func captureReadingProgress() -> StudyProgress? {
        guard currentDocumentID != nil else { return nil }
        return StudyProgress(
            pageIndex: 0,
            pageOffsetY: textView.contentOffset.y,
            pageOffsetX: textView.contentOffset.x,
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
        textView.setContentOffset(CGPoint(x: 0, y: max(0, y)), animated: false)
        syncLineNumberOffset()
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
        guard currentDocumentID != nil else { return "无文档" }
        let lines = max((textView.text as NSString?)?.length ?? 0 > 0
            ? (textView.text as NSString).components(separatedBy: "\n").count : 0, 1)
        let mode: String
        if readSurface == .diff {
            mode = "Diff"
        } else if readSurface == .diffPreview {
            mode = "阅读 · 提案预览"
        } else if language == .markdown {
            mode = isEditMode ? "编辑" : "预览"
        } else {
            mode = isEditMode ? "编辑" : "阅读"
        }
        let dirty = (isEditMode && isDirty) ? " · 未保存" : ""
        return "\(language.displayName) · \(mode) · \(lines) 行\(dirty)"
    }

    func currentPageText() -> String? {
        currentPlainText()
    }

    // MARK: - Private

    @objc private func sidebarTapped() {
        onToggleSidebar?()
    }

    @objc private func saveTapped() {
        flushSaveIfNeeded(force: true, showSuccessToast: true)
    }

    @objc private func themeChanged() {
        applyChromeColors()
        refreshTextPresentationPreservingDiff()
        updateLineNumbers(force: true)
        syncLineNumberOffset()
        if language == .markdown {
            previewShellLoaded = false
            if showsMarkdownPreview {
                refreshMarkdownPreview(text: textView.text ?? "")
            }
        }
    }

    private func applyChromeColors() {
        let c = DSTheme.c
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
        lineNumberView.textColor = c.textTertiary
        lineNumberView.backgroundColor = .clear
        progressLabel.textColor = c.textSecondary
        modeButton.tintColor = c.textSecondary
        saveButton.tintColor = isEditMode ? c.accent : c.textTertiary
        textView.typingAttributes = CodeSyntaxHighlighter.typingAttributes(fontSize: fontPointSize)
        refreshModeChrome()
    }

    @objc private func handleFontPinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchBaseFontSize = fontPointSize
        case .changed:
            let next = min(
                Self.maxFontPointSize,
                max(Self.minFontPointSize, pinchBaseFontSize * gesture.scale)
            )
            guard abs(next - fontPointSize) >= 0.4 else { return }
            applyFontSize(next, persist: false)
        case .ended, .cancelled:
            applyFontSize(fontPointSize, persist: true)
        default:
            break
        }
    }

    private func applyFontSize(_ size: CGFloat, persist: Bool) {
        fontPointSize = size
        lineNumberView.font = CodeSyntaxHighlighter.font(size: fontPointSize)
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
        let next = min(Self.maxFontPointSize, max(Self.minFontPointSize, fontPointSize + delta))
        guard abs(next - fontPointSize) >= 0.1 else { return }
        applyFontSize(next, persist: true)
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
        if next {
            focusForKeyboardEditing()
        }
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
        if next {
            focusForKeyboardEditing()
        }
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
        }
    }

    private func refreshModeChrome() {
        let c = DSTheme.c
        if isDiffSessionActive {
            // During Diff: button means "switch Diff / 阅读预览".
            let showingDiff = readSurface == .diff
            let modeKind: ActionIconFactory.Kind = showingDiff ? .readMode : .editMode
            modeButton.setTitle(nil, for: .normal)
            modeButton.setImage(ActionIconFactory.image(modeKind, pointSize: 18), for: .normal)
            modeButton.tintColor = c.accent
            modeButton.isEnabled = true
            modeButton.alpha = 1
            modeButton.accessibilityLabel = showingDiff
                ? "查看提案预览（全部 Keep）"
                : "返回 Diff"
        } else {
            let modeKind: ActionIconFactory.Kind = isEditMode ? .readMode : .editMode
            modeButton.setTitle(nil, for: .normal)
            modeButton.setImage(ActionIconFactory.image(modeKind, pointSize: 18), for: .normal)
            modeButton.tintColor = c.textSecondary
            modeButton.isEnabled = true
            modeButton.alpha = 1
            if language == .markdown {
                modeButton.accessibilityLabel = isEditMode ? "切换到预览模式" : "切换到编辑模式"
            } else {
                modeButton.accessibilityLabel = isEditMode ? "切换到阅读模式" : "切换到编辑模式"
            }
        }
        saveButton.setTitle(nil, for: .normal)
        saveButton.setImage(ActionIconFactory.image(.save, pointSize: 18), for: .normal)
        saveButton.isHidden = false
        saveButton.isEnabled = isEditMode && !isDiffSessionActive
        saveButton.alpha = saveButton.isEnabled ? 1 : 0.35
        saveButton.tintColor = saveButton.isEnabled ? c.accent : c.textTertiary
    }

    private func syncSurfaceVisibility() {
        let preview = showsMarkdownPreview
        previewWebView.isHidden = !preview
        textView.isHidden = preview
        gutterView.isHidden = preview
        gutterSeparator.isHidden = preview
        lineNumberView.isHidden = preview
    }

    private func refreshMarkdownPreview(text: String) {
        loadPreviewShellIfNeeded()
        pendingPreviewMarkdown = text
        tryInjectPendingPreview()
    }

    private func loadPreviewShellIfNeeded() {
        guard !previewShellLoaded else { return }
        let html = MarkdownHTMLRenderer.studyShellHTML(
            textColor: DSTheme.c.textPrimary,
            backgroundColor: DSTheme.c.background,
            secondaryColor: DSTheme.c.textSecondary,
            fontSize: 17
        )
        previewWebView.loadHTMLString(html, baseURL: MarkdownHTMLRenderer.resourceBaseURL)
    }

    private func tryInjectPendingPreview() {
        guard previewShellLoaded, let md = pendingPreviewMarkdown else { return }
        pendingPreviewMarkdown = nil
        let js = MarkdownHTMLRenderer.renderJavaScript(content: md)
        previewWebView.evaluateJavaScript(js, completionHandler: nil)
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
                let tint = DSTheme.c.accent.withAlphaComponent(0.28)
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

        let layout = textView.layoutManager
        let ns = (textView.text ?? "") as NSString
        var rows: [String] = []
        var logicalLine = 1
        let glyphCount = layout.numberOfGlyphs

        if glyphCount == 0 {
            rows = ["1"]
        } else {
            var glyphIndex = 0
            while glyphIndex < glyphCount {
                var fragmentRange = NSRange()
                _ = layout.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &fragmentRange)
                let charRange = layout.characterRange(forGlyphRange: fragmentRange, actualGlyphRange: nil)
                let isFirstFragment: Bool
                if charRange.location == 0 {
                    isFirstFragment = true
                } else if charRange.location < ns.length {
                    isFirstFragment = ns.character(at: charRange.location - 1) == 10 // \n
                } else {
                    isFirstFragment = false
                }
                rows.append(isFirstFragment ? "\(logicalLine)" : "")
                if isFirstFragment { logicalLine += 1 }
                glyphIndex = NSMaxRange(fragmentRange)
            }
            if ns.length > 0, ns.character(at: ns.length - 1) == 10 {
                rows.append("\(logicalLine)")
            }
        }

        let numbers = rows.joined(separator: "\n")
        let digits = "\(max(logicalLine - 1, 1))".count
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
        if force || gutterChanged || lineNumberView.text != numbers {
            let attrs = CodeSyntaxHighlighter.lineNumberAttributes(fontSize: fontPointSize)
            lineNumberView.attributedText = NSAttributedString(string: numbers, attributes: attrs)
            lineNumberView.textAlignment = .right
        }
        syncLineNumberOffset()
    }

    private func syncLineNumberOffset() {
        guard !isSyncingLineNumbers else { return }
        isSyncingLineNumbers = true
        let y = textView.contentOffset.y
        let target = CGPoint(x: 0, y: y)
        if abs(lineNumberView.contentOffset.y - y) > 0.5 {
            lineNumberView.setContentOffset(target, animated: false)
        }
        // Keep contentSize tall enough so twin scroll does not clamp early.
        if lineNumberView.contentSize.height + 1 < textView.contentSize.height {
            lineNumberView.contentSize = CGSize(
                width: max(lineNumberView.bounds.width, 1),
                height: textView.contentSize.height
            )
            lineNumberView.setContentOffset(target, animated: false)
        }
        isSyncingLineNumbers = false
    }

    private func updateProgressLabel() {
        progressLabel.text = currentPageLabel()
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
    func debugLineNumberContentOffsetY() -> CGFloat { lineNumberView.contentOffset.y }
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
        [
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
            makeEditorKeyCommand(input: "\t", modifiers: [],
                                 action: #selector(shortcutAcceptGhost), title: "Accept Tab"),
            makeEditorKeyCommand(input: "y", modifiers: [],
                                 action: #selector(shortcutDiffAccept), title: "Keep Diff"),
            makeEditorKeyCommand(input: "n", modifiers: [],
                                 action: #selector(shortcutDiffReject), title: "Undo Diff")
        ]
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
        let text = textView.text ?? ""
        var range = textView.selectedRange
        if let pinned = askPinnedRange, pinned.length > 0 {
            range = pinned
        }
        return (text, range)
    }

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

    func enterEditModeAfterKeep() {
        readSurface = .plain
        syncDiffChrome(show: false)
        applyEditMode(true)
        focusForKeyboardEditing()
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
            textColor: DSTheme.c.textPrimary,
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
        let c = DSTheme.c
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
            textColor: DSTheme.c.textPrimary,
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
        bar.backgroundColor = DSTheme.c.surface.withAlphaComponent(0.82)
        bar.layer.cornerRadius = 8
        bar.layer.borderWidth = 1 / UIScreen.main.scale
        bar.layer.borderColor = DSTheme.c.border.withAlphaComponent(0.55).cgColor
        bar.clipsToBounds = true
        bar.tag = segIdx

        let c = DSTheme.c
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
        undo.setTitle("Undo", for: .normal)
        undo.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        undo.backgroundColor = UIColor(red: 0.75, green: 0.18, blue: 0.18, alpha: 0.88)
        undo.setTitleColor(.white, for: .normal)
        undo.layer.cornerRadius = 6
        undo.tag = segIdx
        undo.addTarget(self, action: #selector(diffUndoHunkAtButton(_:)), for: .touchUpInside)

        let keep = UIButton(type: .system)
        keep.translatesAutoresizingMaskIntoConstraints = false
        keep.setTitle("Keep", for: .normal)
        keep.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        keep.backgroundColor = UIColor(red: 0.10, green: 0.55, blue: 0.28, alpha: 0.88)
        keep.setTitleColor(.white, for: .normal)
        keep.layer.cornerRadius = 6
        keep.tag = segIdx
        keep.addTarget(self, action: #selector(diffKeepHunkAtButton(_:)), for: .touchUpInside)

        bar.addSubview(undo)
        bar.addSubview(keep)
        // Fixed equal widths — "Undo"/"Keep" intrinsic sizes differ and looked uneven.
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
                // Coordinator applies final text + enters edit mode.
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
            enterEditModeAfterKeep()
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

    @objc private func tabToggleTapped() {
        tabCompletionEnabled.toggle()
        UserDefaults.standard.set(tabCompletionEnabled, forKey: "connects.codeEditor.tabCompletion")
        refreshTabToggleChrome()
        if !tabCompletionEnabled { clearGhostSuggestion() }
    }

    private func refreshTabToggleChrome() {
        let c = DSTheme.c
        let usable = isEditMode && !isDiffSessionActive
        let on = tabCompletionEnabled && usable
        tabToggleButton.isHidden = false
        tabToggleButton.alpha = usable ? 1 : 0.35
        tabToggleButton.isEnabled = usable
        tabToggleButton.setTitleColor(on ? c.accent : c.textSecondary, for: .normal)
        tabToggleButton.backgroundColor = on ? c.accent.withAlphaComponent(0.14) : .clear
        tabToggleButton.layer.cornerRadius = 8
        tabToggleButton.accessibilityValue = tabCompletionEnabled ? "开" : "关"
        tabToggleButton.accessibilityHint = "仅开关补全；接受请用光标旁 Accept"
        tabConfirmButton.setTitleColor(c.accent, for: .normal)
        tabDismissButton.setTitleColor(c.textSecondary, for: .normal)
        tabSuggestChip.backgroundColor = c.surface
        tabSuggestChip.layer.borderColor = c.border.cgColor
        diffHunkBar.backgroundColor = c.surface.withAlphaComponent(0.78)
        diffHunkBar.layer.borderColor = c.border.withAlphaComponent(0.55).cgColor
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
        guard tabCompletionEnabled, isEditMode, !isDiffSessionActive else { return }
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
            textView.scrollIndicatorInsets = insets
        }
        var gutterInsets = lineNumberView.contentInset
        if gutterInsets.bottom != 0 {
            gutterInsets.bottom = 0
            lineNumberView.contentInset = gutterInsets
            lineNumberView.scrollIndicatorInsets = gutterInsets
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
        tryInjectPendingPreview()
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
