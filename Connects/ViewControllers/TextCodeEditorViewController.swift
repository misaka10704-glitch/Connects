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
    private let textView = StudyAskTextView()
    private let spinner = UIActivityIndicatorView(style: .gray)
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
    private var highlightWorkItem: DispatchWorkItem?
    /// Ask 选区：语法高亮之上的持久背景，不依赖系统选区（用户可先读后开 AI）。
    private var askPinnedRange: NSRange?
    private var saveWorkItem: DispatchWorkItem?
    private var isApplyingHighlight = false
    private var isSyncingLineNumbers = false
    private var readerSurfaceActive = true
    private var pendingViewportProgress: StudyProgress?
    private var conversationIDForDirty: String?

    // MARK: - Future: AI edit / Tab completion / inline diff (see CodeEditorAIBridge.swift)
    weak var aiEditing: CodeEditorAIEditing?
    weak var completionProvider: CodeEditorCompletionProviding?
    weak var diffPresenter: CodeEditorDiffPresenting?

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
        language == .markdown && !isEditMode
    }

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

        let config = WKWebViewConfiguration()
        previewWebView = WKWebView(frame: .zero, configuration: config)
        previewWebView.translatesAutoresizingMaskIntoConstraints = false
        previewWebView.isOpaque = false
        previewWebView.backgroundColor = DSTheme.c.background
        previewWebView.scrollView.backgroundColor = DSTheme.c.background
        previewWebView.isHidden = true
        previewWebView.navigationDelegate = self
        if #available(iOS 11.0, *) {
            previewWebView.scrollView.contentInsetAdjustmentBehavior = .never
        }
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
            progressLabel.trailingAnchor.constraint(lessThanOrEqualTo: modeButton.leadingAnchor, constant: -4),

            // Far-right chrome: [mode][save], fixed 40pt slots (never collapse).
            saveButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -4),
            saveButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            saveButton.widthAnchor.constraint(equalToConstant: 40),
            saveButton.heightAnchor.constraint(equalToConstant: 40),

            modeButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -2),
            modeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            modeButton.widthAnchor.constraint(equalToConstant: 40),
            modeButton.heightAnchor.constraint(equalToConstant: 40),

            topBarSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBarSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBarSeparator.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            topBarSeparator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            gutterView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gutterView.topAnchor.constraint(equalTo: topBarSeparator.bottomAnchor),
            gutterView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            gutterWidthConstraint,

            lineNumberView.leadingAnchor.constraint(equalTo: gutterView.leadingAnchor),
            lineNumberView.trailingAnchor.constraint(equalTo: gutterView.trailingAnchor),
            lineNumberView.topAnchor.constraint(equalTo: gutterView.topAnchor),
            lineNumberView.bottomAnchor.constraint(equalTo: gutterView.bottomAnchor),

            gutterSeparator.leadingAnchor.constraint(equalTo: gutterView.trailingAnchor, constant: 6),
            gutterSeparator.topAnchor.constraint(equalTo: topBarSeparator.bottomAnchor),
            gutterSeparator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            gutterSeparator.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            textView.leadingAnchor.constraint(equalTo: gutterSeparator.trailingAnchor, constant: 10),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.topAnchor.constraint(equalTo: topBarSeparator.bottomAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            previewWebView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewWebView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewWebView.topAnchor.constraint(equalTo: topBarSeparator.bottomAnchor),
            previewWebView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

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
        if language == .markdown {
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
        applyHighlightedText(textView.text ?? "")
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
        applyHighlightedText(textView.text ?? "")
        updateLineNumbers(force: true)
        syncLineNumberOffset()
        if persist {
            UserDefaults.standard.set(Double(fontPointSize), forKey: Self.fontSizeDefaultsKey)
        }
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

    /// Shell / hardware keyboard: ⌘M toggles read(preview) ↔ edit.
    func toggleEditModeFromKeyboardShortcut() {
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
        applyEditMode(!isEditMode)
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
        if !editing {
            // Avoid flush/resign during viewDidLoad (view not in a window yet).
            if isViewLoaded, view.window != nil {
                flushSaveIfNeeded(force: true)
                textView.resignFirstResponder()
            }
        }
        isEditMode = editing
        textView.isEditable = editing
        textView.isSelectable = true
        refreshModeChrome()
        updateProgressLabel()
        syncSurfaceVisibility()
        if showsMarkdownPreview {
            refreshMarkdownPreview(text: textView.text ?? "")
        }
    }

    private func refreshModeChrome() {
        let c = DSTheme.c
        // Read/preview → pencil (enter edit). Edit → eye (enter read/preview).
        let modeKind: ActionIconFactory.Kind = isEditMode ? .readMode : .editMode
        modeButton.setTitle(nil, for: .normal)
        modeButton.setImage(ActionIconFactory.image(modeKind, pointSize: 18), for: .normal)
        modeButton.tintColor = c.textSecondary
        if language == .markdown {
            modeButton.accessibilityLabel = isEditMode ? "切换到预览模式" : "切换到编辑模式"
        } else {
            modeButton.accessibilityLabel = isEditMode ? "切换到阅读模式" : "切换到编辑模式"
        }
        saveButton.setTitle(nil, for: .normal)
        saveButton.setImage(ActionIconFactory.image(.save, pointSize: 18), for: .normal)
        saveButton.isHidden = false
        saveButton.isEnabled = isEditMode
        saveButton.alpha = isEditMode ? 1 : 0.35
        saveButton.tintColor = isEditMode ? c.accent : c.textTertiary
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
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        // Apply any deferred gutter width change now that reflow won't yank the caret.
        updateLineNumbers(force: true, allowImmediateLayout: true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === textView else { return }
        syncLineNumberOffset()
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
    }
    func debugSetEditMode(_ editing: Bool) {
        applyEditMode(editing)
        view.layoutIfNeeded()
    }
    func debugTopChromeFrames() -> (mode: CGRect, save: CGRect) {
        (modeButton.convert(modeButton.bounds, to: view),
         saveButton.convert(saveButton.bounds, to: view))
    }
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
                                 action: #selector(shortcutLineEnd), title: "跳到文字行末")
        ]
    }

    private func makeEditorKeyCommand(input: String,
                                      modifiers: UIKeyModifierFlags,
                                      action: Selector,
                                      title: String) -> UIKeyCommand {
        if #available(iOS 13.0, *) {
            let cmd = UIKeyCommand(title: title, action: action, input: input, modifierFlags: modifiers)
            if #available(iOS 15.0, *) {
                cmd.wantsPriorityOverSystemBehavior = true
            }
            return cmd
        }
        let cmd = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
        cmd.discoverabilityTitle = title
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
