import UIKit
import WebKit

/// Study-mode Markdown reader — same shell role as `PDFReaderViewController`.
/// Legacy Study Markdown reader (read/edit + Build).
/// Canonical path: `.md` opens in `TextCodeEditorViewController` (preview + edit).
/// Keep this VC only for rare stored `kind == .markdown` fallback loads.
final class MarkdownReaderViewController: UIViewController, WKNavigationDelegate, WKScriptMessageHandler, UITextViewDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let topBar = UIView()
    private let sidebarButton = UIButton(type: .system)
    private let contentsButton = UIButton(type: .system)
    private let appearanceButton = UIButton(type: .system)
    private let modeButton = UIButton(type: .system)
    private let buildButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let progressLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var webView: StudyAskWebView!
    private let editorView = StudyAskTextView()
    private var isEditMode = false
    private var isDirty = false
    private var saveWorkItem: DispatchWorkItem?
    private let contentsPanelHost = UIView()
    private let contentsDim = UIControl()
    private let contentsVC = MarkdownContentsViewController()
    private var progressWorkItem: DispatchWorkItem?
    private var currentDocumentID: String?
    private var markdownSource: String = ""
    private var loadGeneration: UInt = 0
    private var sidebarButtonWidthConstraint: NSLayoutConstraint!
    private var buildButtonWidthConstraint: NSLayoutConstraint!
    private var contentsPanelWidth: NSLayoutConstraint!
    private var contentsPanelTrailing: NSLayoutConstraint!
    private var isContentsPanelVisible = false
    private let contentsPanelWidthConstant: CGFloat = 220
    private var shellLoaded = false
    private var pendingMarkdown: String?
    private let previewAssetHandler = MarkdownPreviewAssetSchemeHandler()
    private var pendingViewportProgress: StudyProgress?
    private var isRestoringViewport = false
    private var isShellRotating = false
    private var shellRotationProgress: StudyProgress?
    private var readerSurfaceActive = true
    private var contentReady = false
    private var askPinnedEditorRange: NSRange?
    /// Throttle top chrome % updates so scroll-path stays finger-tracking.
    private var lastProgressLabelAt: CFTimeInterval = 0
    private var lastProgressLabelPct: Int = -1

    private static let fontSizeDefaultsKey = "connects.markdownPreview.fontSize"
    private static let minFontPointSize: CGFloat = 11
    /// iPhone 26 / iPad 32.
    private static var maxFontPointSize: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 32 : 26
    }
    private var fontPointSize: CGFloat = {
        let max = MarkdownReaderViewController.maxFontPointSize
        let stored = UserDefaults.standard.double(forKey: MarkdownReaderViewController.fontSizeDefaultsKey)
        if stored >= 11, stored <= Double(max) { return CGFloat(stored) }
        if stored > Double(max) { return max }
        return 17
    }()
    private var pinchBaseFontSize: CGFloat = 17

    var onPageChanged: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onAskSelection: ((String) -> Void)?
    var onFileTitleTapped: ((UIView) -> Void)?
    var onBuildPlan: (() -> Void)?

    private var isPlanDocument = false

    /// Persist Ask highlight on the current selection; does not open AI.
    func pinAskSelectionHighlight() {
        if isEditMode {
            let range = editorView.selectedRange
            let length = (editorView.text as NSString?)?.length ?? 0
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
            guard clamped.length > 0 else { return }
            askPinnedEditorRange = clamped
            paintAskEditorHighlight()
            editorView.selectedRange = clamped
            if #available(iOS 13.0, *) {
                UIMenuController.shared.hideMenu(from: editorView)
            } else {
                UIMenuController.shared.setMenuVisible(false, animated: true)
            }
            return
        }
        pinAskWebHighlight()
    }

    func clearAskSelectionHighlight() {
        askPinnedEditorRange = nil
        if isEditMode {
            let plain = editorView.text ?? ""
            editorView.attributedText = NSAttributedString(
                string: plain,
                attributes: [
                    .font: editorView.font ?? UIFont.systemFont(ofSize: 16),
                    .foregroundColor: DSTheme.reader.textPrimary
                ]
            )
        } else {
            webView.evaluateJavaScript(Self.clearAskWebHighlightJS, completionHandler: nil)
        }
    }

    /// Text pinned by Ask; fallback when `StudyAskSelectionStore` lookup misses on send.
    func pinnedAskText() -> String? {
        if isEditMode, let pinned = askPinnedEditorRange {
            let plain = editorView.text ?? ""
            let clamped = NSIntersectionRange(pinned, NSRange(location: 0, length: (plain as NSString).length))
            guard clamped.length > 0 else { return nil }
            let text = (plain as NSString).substring(with: clamped)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private func paintAskEditorHighlight() {
        let plain = editorView.text ?? ""
        let attrs: [NSAttributedString.Key: Any] = [
            .font: editorView.font ?? UIFont.systemFont(ofSize: 16),
            .foregroundColor: DSTheme.reader.textPrimary
        ]
        let mutable = NSMutableAttributedString(string: plain, attributes: attrs)
        if let pinned = askPinnedEditorRange {
            let clamped = NSIntersectionRange(pinned, NSRange(location: 0, length: (plain as NSString).length))
            if clamped.length > 0 {
                mutable.addAttribute(
                    .backgroundColor,
                    value: DSTheme.reader.accent.withAlphaComponent(0.28),
                    range: clamped
                )
            }
        }
        let selected = editorView.selectedRange
        editorView.attributedText = mutable
        editorView.selectedRange = selected
    }

    private func pinAskWebHighlight() {
        webView.evaluateJavaScript(Self.pinAskWebHighlightJS, completionHandler: nil)
    }

    private static let pinAskWebHighlightJS = """
    (function(){
      document.querySelectorAll('mark.connects-ask').forEach(function(m){
        var p = m.parentNode; if (!p) return;
        while (m.firstChild) p.insertBefore(m.firstChild, m);
        p.removeChild(m); p.normalize();
      });
      var sel = window.getSelection();
      if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return false;
      var range = sel.getRangeAt(0);
      var mark = document.createElement('mark');
      mark.className = 'connects-ask';
      mark.style.background = 'rgba(64,140,255,0.35)';
      mark.style.color = 'inherit';
      try {
        mark.appendChild(range.extractContents());
        range.insertNode(mark);
      } catch (e) { return false; }
      sel.removeAllRanges();
      var keep = document.createRange();
      keep.selectNodeContents(mark);
      sel.addRange(keep);
      return true;
    })();
    """

    private static let clearAskWebHighlightJS = """
    (function(){
      document.querySelectorAll('mark.connects-ask').forEach(function(m){
        var p = m.parentNode; if (!p) return;
        while (m.firstChild) p.insertBefore(m.firstChild, m);
        p.removeChild(m); p.normalize();
      });
      return true;
    })();
    """

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DSTheme.c.background

        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        sidebarButton.translatesAutoresizingMaskIntoConstraints = false
        sidebarButton.addTarget(self, action: #selector(sidebarTapped), for: .touchUpInside)
        sidebarButton.accessibilityLabel = "打开侧栏"
        topBar.addSubview(sidebarButton)
        updateSidebarToggle(collapsed: true)
        sidebarButtonWidthConstraint = sidebarButton.widthAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget)

        contentsButton.translatesAutoresizingMaskIntoConstraints = false
        contentsButton.setImage(ActionIconFactory.image(.toc, pointSize: ActionIconFactory.chromeGlyph), for: .normal)
        contentsButton.tintColor = DSTheme.c.textSecondary
        contentsButton.accessibilityLabel = "目录"
        contentsButton.addTarget(self, action: #selector(contentsTapped), for: .touchUpInside)
        topBar.addSubview(contentsButton)

        appearanceButton.translatesAutoresizingMaskIntoConstraints = false
        appearanceButton.addTarget(self, action: #selector(appearanceTapped), for: .touchUpInside)
        topBar.addSubview(appearanceButton)
        updateAppearanceButton()

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
        saveButton.isEnabled = false
        saveButton.alpha = 0.35
        topBar.addSubview(saveButton)

        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        progressLabel.textColor = DSTheme.reader.textPrimary
        progressLabel.textAlignment = .center
        progressLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progressLabel.isUserInteractionEnabled = true
        progressLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(fileTitleTapped)))
        topBar.addSubview(progressLabel)
        // Wide title strip must stay under the trailing chrome controls.
        topBar.bringSubviewToFront(modeButton)
        topBar.bringSubviewToFront(buildButton)
        topBar.bringSubviewToFront(saveButton)
        topBar.bringSubviewToFront(appearanceButton)
        topBar.bringSubviewToFront(contentsButton)

        let controller = WKUserContentController()
        controller.add(WeakScriptMessageHandler(delegate: self), name: "studyReady")
        controller.add(WeakScriptMessageHandler(delegate: self), name: "studyAsset")
        let config = ConnectsWebKit.makeConfiguration(userContentController: controller)
        config.setURLSchemeHandler(previewAssetHandler, forURLScheme: MarkdownPreviewAssetIndex.scheme)

        webView = StudyAskWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        ConnectsWebKit.applyReadingSurfaceTuning(webView, background: DSTheme.reader.background)
        webView.scrollView.delegate = self
        webView.onAskSelection = { [weak self] text in
            self?.onAskSelection?(text)
        }
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handleFontPinch(_:)))
        pinch.delegate = self
        webView.addGestureRecognizer(pinch)
        view.addSubview(webView)

        editorView.translatesAutoresizingMaskIntoConstraints = false
        editorView.font = UIFont(name: "Menlo-Regular", size: 14) ?? UIFont.systemFont(ofSize: 14)
        editorView.backgroundColor = DSTheme.reader.background
        editorView.textColor = DSTheme.reader.textPrimary
        editorView.autocorrectionType = .no
        editorView.autocapitalizationType = .none
        editorView.smartDashesType = .no
        editorView.smartQuotesType = .no
        editorView.keyboardDismissMode = .interactive
        editorView.isHidden = true
        editorView.delegate = self
        editorView.onAskSelection = { [weak self] text in
            self?.onAskSelection?(text)
        }
        if #available(iOS 11.0, *) {
            editorView.contentInsetAdjustmentBehavior = .never
        }
        view.addSubview(editorView)
        StudyAskMenu.installIfNeeded()

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

            progressLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            progressLabel.topAnchor.constraint(equalTo: topBar.topAnchor),
            progressLabel.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            progressLabel.leadingAnchor.constraint(greaterThanOrEqualTo: sidebarButton.trailingAnchor, constant: 4),
            progressLabel.trailingAnchor.constraint(lessThanOrEqualTo: modeButton.leadingAnchor, constant: -4),

            modeButton.trailingAnchor.constraint(equalTo: buildButton.leadingAnchor, constant: -2),
            modeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            modeButton.widthAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),
            modeButton.heightAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),

            buildButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -2),
            buildButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            buildButton.heightAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),
            buildButtonWidthConstraint,

            saveButton.trailingAnchor.constraint(equalTo: appearanceButton.leadingAnchor, constant: -2),
            saveButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            saveButton.widthAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),
            saveButton.heightAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),

            appearanceButton.trailingAnchor.constraint(equalTo: contentsButton.leadingAnchor, constant: -2),
            appearanceButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            appearanceButton.widthAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),
            appearanceButton.heightAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),

            contentsButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -4),
            contentsButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            contentsButton.widthAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),
            contentsButton.heightAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),

            webView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            editorView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            editorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            editorView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        installContentsPanel()
        syncContentsOverlayZOrder()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeChanged),
            name: .themeDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeChanged),
            name: .readerThemeDidChange,
            object: nil
        )
        loadShellIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        flushProgressSave()
    }

    deinit {
        if webView != nil {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "studyReady")
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "studyAsset")
        }
        NotificationCenter.default.removeObserver(self)
    }

    func isLoaded(documentID: String) -> Bool {
        currentDocumentID == documentID && contentReady && !markdownSource.isEmpty
    }

    func setReaderSurfaceActive(_ active: Bool) {
        readerSurfaceActive = active
        if !active {
            pendingViewportProgress = nil
        }
    }

    func updateSidebarToggle(collapsed: Bool) {
        let kind: ActionIconFactory.Kind = collapsed ? .sidebar : .sidebarOpen
        sidebarButton.setImage(ActionIconFactory.image(kind, pointSize: ActionIconFactory.chromeGlyph), for: .normal)
        sidebarButton.tintColor = DSTheme.c.textSecondary
        sidebarButton.accessibilityLabel = collapsed ? "打开侧栏" : "关闭侧栏"
    }

    func setSidebarButtonHidden(_ hidden: Bool, animated: Bool = false) {
        let apply = {
            self.sidebarButton.alpha = hidden ? 0 : 1
            self.sidebarButton.isUserInteractionEnabled = !hidden
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

    @objc private func sidebarTapped() {
        onToggleSidebar?()
    }

    @objc private func contentsTapped() {
        if isContentsPanelVisible {
            setContentsPanelVisible(false, animated: true)
        } else {
            refreshContentsPanel()
            setContentsPanelVisible(true, animated: true)
        }
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
        appearanceButton.tintColor = DSTheme.c.textSecondary
        appearanceButton.accessibilityLabel = dark ? "切换到白天模式" : "切换到黑夜模式"
    }

    @objc private func themeChanged() {
        // Preserve reading Y before the WK shell is rebuilt for new colors.
        if !isEditMode, contentReady || shellLoaded {
            let offset = webView.scrollView.contentOffset
            pendingViewportProgress = StudyProgress(
                pageIndex: 0,
                pageOffsetY: offset.y,
                pageOffsetX: offset.x,
                anchorX: nil,
                anchorY: nil,
                scaleFactor: nil,
                updatedAt: Date()
            )
        } else if isEditMode, shellLoaded {
            // Edit mode: web is hidden but still holds the last read offset until reload.
            let offset = webView.scrollView.contentOffset
            if offset.y > 1 || offset.x > 1 {
                pendingViewportProgress = StudyProgress(
                    pageIndex: 0,
                    pageOffsetY: offset.y,
                    pageOffsetX: offset.x,
                    anchorX: nil,
                    anchorY: nil,
                    scaleFactor: nil,
                    updatedAt: Date()
                )
            }
        }
        let chrome = DSTheme.c
        view.backgroundColor = chrome.background
        topBar.backgroundColor = chrome.background
        ConnectsWebKit.applyReadingSurfaceTuning(webView, background: DSTheme.reader.background)
        webView.scrollView.delegate = self
        editorView.backgroundColor = DSTheme.reader.background
        editorView.textColor = DSTheme.reader.textPrimary
        progressLabel.textColor = chrome.textSecondary
        sidebarButton.tintColor = chrome.textSecondary
        contentsButton.tintColor = chrome.textSecondary
        updateAppearanceButton()
        refreshModeChrome()
        contentsPanelHost.backgroundColor = chrome.background
        contentsPanelHost.layer.borderColor = chrome.border.cgColor
        shellLoaded = false
        contentReady = false
        loadShellIfNeeded()
        if !markdownSource.isEmpty {
            pendingMarkdown = markdownSource
            tryInjectPendingMarkdown()
        }
    }

    @objc private func modeTapped() {
        if isEditMode {
            flushMarkdownSaveIfNeeded()
            setEditMode(false)
        } else {
            setEditMode(true)
        }
    }

    @objc private func saveTapped() {
        flushMarkdownSaveIfNeeded(force: true)
    }

    @objc private func buildTapped() {
        onBuildPlan?()
    }

    private func updateBuildButtonVisibility() {
        let show = isPlanDocument && onBuildPlan != nil
        buildButton.isHidden = !show
        buildButtonWidthConstraint.constant = show ? 56 : 0
        buildButton.setTitleColor(DSTheme.reader.accent, for: .normal)
        buildButton.isUserInteractionEnabled = show
        if show {
            // Keep Build above sibling chrome so taps aren't swallowed.
            topBar.bringSubviewToFront(buildButton)
        }
    }

    private func setEditMode(_ editing: Bool) {
        isEditMode = editing
        refreshModeChrome()
        contentsButton.isHidden = editing
        webView.isHidden = editing
        editorView.isHidden = !editing
        if editing {
            editorView.text = markdownSource
            // Don't auto-focus — wait until the user taps into the editor.
        } else {
            editorView.resignFirstResponder()
            pendingMarkdown = markdownSource
            tryInjectPendingMarkdown()
            refreshContentsPanel()
        }
        updateProgressLabel()
    }

    private func refreshModeChrome() {
        let c = DSTheme.reader
        let modeKind: ActionIconFactory.Kind = isEditMode ? .readMode : .editMode
        modeButton.setTitle(nil, for: .normal)
        modeButton.setImage(ActionIconFactory.image(modeKind, pointSize: ActionIconFactory.chromeGlyph), for: .normal)
        modeButton.tintColor = c.textSecondary
        modeButton.accessibilityLabel = isEditMode ? "切换到阅读模式" : "切换到编辑模式"
        saveButton.setTitle(nil, for: .normal)
        saveButton.setImage(ActionIconFactory.image(.save, pointSize: ActionIconFactory.chromeGlyph), for: .normal)
        saveButton.isHidden = false
        saveButton.isEnabled = isEditMode
        saveButton.alpha = isEditMode ? 1 : 0.35
        saveButton.tintColor = isEditMode ? c.accent : c.textTertiary
        saveButton.accessibilityLabel = "保存"
        updateBuildButtonVisibility()
    }

    /// Keyboard shortcut: enter Markdown edit mode and focus the editor.
    func focusForKeyboardEditing() {
        if !isEditMode {
            setEditMode(true)
        }
        _ = editorView.becomeFirstResponder()
    }

    var isMarkdownEditorFirstResponder: Bool {
        isEditMode && editorView.isFirstResponder
    }

    func saveFromKeyboardShortcut() {
        flushMarkdownSaveIfNeeded(force: true)
    }

    /// Shell / hardware keyboard: ⌘+ / ⌘- (same as code editor zoom).
    func adjustFontSizeFromKeyboardShortcut(by delta: CGFloat) {
        guard !isEditMode else { return }
        let next = min(Self.maxFontPointSize, max(Self.minFontPointSize, fontPointSize + delta))
        guard abs(next - fontPointSize) >= 0.1 else { return }
        applyFontSize(next, persist: true)
        let pt = Int(next.rounded())
        ConnectsToast.show("字号 \(pt)", in: view, duration: 0.7)
    }

    @objc private func handleFontPinch(_ gesture: UIPinchGestureRecognizer) {
        guard !isEditMode else { return }
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
            let pt = Int(fontPointSize.rounded())
            ConnectsToast.show("字号 \(pt)", in: view, duration: 0.7)
        default:
            break
        }
    }

    private func applyFontSize(_ size: CGFloat, persist: Bool) {
        fontPointSize = min(Self.maxFontPointSize, max(Self.minFontPointSize, size))
        if persist {
            UserDefaults.standard.set(Double(fontPointSize), forKey: Self.fontSizeDefaultsKey)
        }
        guard shellLoaded else { return }
        webView.evaluateJavaScript(
            MarkdownHTMLRenderer.setFontSizeJavaScript(fontPointSize),
            completionHandler: nil
        )
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UIPinchGestureRecognizer
    }

    private func flushMarkdownSaveIfNeeded(force: Bool = false) {
        guard let docID = currentDocumentID else { return }
        if isEditMode {
            markdownSource = editorView.text ?? markdownSource
        }
        guard isDirty || force else { return }
        guard isDirty else { return }
        do {
            try StudyDocumentStore.shared.writeTextContent(markdownSource, for: docID)
            isDirty = false
            updateProgressLabel()
            ConnectsToast.show("已保存", in: view, duration: 1.0)
        } catch {
            ConnectsToast.show("保存失败：\(error.localizedDescription)", in: view, duration: 2.0)
        }
    }

    private func scheduleMarkdownAutosave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushMarkdownSaveIfNeeded(force: true)
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    func textViewDidChange(_ textView: UITextView) {
        guard textView === editorView else { return }
        if askPinnedEditorRange != nil {
            askPinnedEditorRange = nil
        }
        isDirty = true
        markdownSource = textView.text ?? ""
        let wasPlan = isPlanDocument
        isPlanDocument = StudyPlanDocument.parse(markdownSource).isPlan
        if wasPlan != isPlanDocument {
            updateBuildButtonVisibility()
        }
        updateProgressLabel()
        scheduleMarkdownAutosave()
    }

    private func installContentsPanel() {
        contentsDim.translatesAutoresizingMaskIntoConstraints = false
        contentsDim.backgroundColor = UIColor.black.withAlphaComponent(0.08)
        contentsDim.alpha = 0
        contentsDim.isHidden = true
        contentsDim.addTarget(self, action: #selector(contentsDimTapped), for: .touchUpInside)
        view.addSubview(contentsDim)

        contentsPanelHost.translatesAutoresizingMaskIntoConstraints = false
        contentsPanelHost.backgroundColor = DSTheme.reader.background
        contentsPanelHost.layer.shadowColor = UIColor.black.cgColor
        contentsPanelHost.layer.shadowOpacity = 0.12
        contentsPanelHost.layer.shadowRadius = 8
        contentsPanelHost.layer.shadowOffset = CGSize(width: -2, height: 0)
        contentsPanelHost.layer.borderWidth = 1.0 / UIScreen.main.scale
        contentsPanelHost.layer.borderColor = DSTheme.reader.border.cgColor
        contentsPanelHost.isHidden = true
        view.addSubview(contentsPanelHost)

        addChild(contentsVC)
        contentsVC.view.translatesAutoresizingMaskIntoConstraints = false
        contentsPanelHost.addSubview(contentsVC.view)
        contentsVC.didMove(toParent: self)

        contentsVC.onSelectHeadingID = { [weak self] headingID in
            self?.scrollToHeading(id: headingID)
        }

        contentsPanelWidth = contentsPanelHost.widthAnchor.constraint(equalToConstant: contentsPanelWidthConstant)
        contentsPanelTrailing = contentsPanelHost.trailingAnchor.constraint(
            equalTo: view.trailingAnchor,
            constant: contentsPanelWidthConstant
        )

        NSLayoutConstraint.activate([
            contentsDim.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            contentsDim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentsDim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentsDim.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentsPanelHost.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            contentsPanelHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentsPanelWidth,
            contentsPanelTrailing,

            contentsVC.view.topAnchor.constraint(equalTo: contentsPanelHost.topAnchor),
            contentsVC.view.leadingAnchor.constraint(equalTo: contentsPanelHost.leadingAnchor),
            contentsVC.view.trailingAnchor.constraint(equalTo: contentsPanelHost.trailingAnchor),
            contentsVC.view.bottomAnchor.constraint(equalTo: contentsPanelHost.bottomAnchor)
        ])
    }

    @objc private func contentsDimTapped() {
        setContentsPanelVisible(false, animated: true)
    }

    private func refreshContentsPanel() {
        guard contentReady else {
            contentsVC.setHeadings([])
            return
        }
        webView.evaluateJavaScript("window.__connectsHeadingOutline && window.__connectsHeadingOutline();") { [weak self] result, _ in
            guard let self = self else { return }
            let headings = Self.parseHeadingOutline(result)
            self.contentsVC.setHeadings(headings)
        }
    }

    private func scrollToHeading(id: String) {
        let escaped = id
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = "window.__connectsScrollToHeading && window.__connectsScrollToHeading('\(escaped)');"
        webView.evaluateJavaScript(js) { [weak self] _, _ in
            guard let self = self else { return }
            self.setContentsPanelVisible(false, animated: true)
            self.updateProgressLabel()
            self.scheduleProgressSave()
            self.onPageChanged?()
        }
    }

    private static func parseHeadingOutline(_ result: Any?) -> [MarkdownContentsViewController.HeadingRow] {
        guard let raw = result as? String,
              let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { item in
            guard let id = item["id"] as? String,
                  let title = item["title"] as? String,
                  !title.isEmpty else { return nil }
            let level = (item["level"] as? Int) ?? 1
            return MarkdownContentsViewController.HeadingRow(id: id, title: title, level: level)
        }
    }

    private func syncContentsOverlayZOrder() {
        if isContentsPanelVisible {
            view.bringSubviewToFront(contentsDim)
        }
        view.bringSubviewToFront(contentsPanelHost)
        view.bringSubviewToFront(topBar)
        view.bringSubviewToFront(spinner)
        topBar.bringSubviewToFront(modeButton)
        topBar.bringSubviewToFront(buildButton)
        topBar.bringSubviewToFront(saveButton)
        topBar.bringSubviewToFront(appearanceButton)
        topBar.bringSubviewToFront(contentsButton)
    }

    private func setContentsPanelVisible(_ visible: Bool, animated: Bool) {
        isContentsPanelVisible = visible
        if visible {
            contentsDim.isHidden = false
            syncContentsOverlayZOrder()
        }
        contentsPanelHost.isHidden = false
        contentsPanelTrailing.constant = visible ? 0 : contentsPanelWidthConstant
        let updates = {
            self.view.layoutIfNeeded()
            self.contentsDim.alpha = visible ? 1 : 0
        }
        if animated {
            UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseOut], animations: updates) { _ in
                self.contentsPanelHost.isHidden = !visible
                if !visible {
                    self.contentsDim.isHidden = true
                }
            }
        } else {
            updates()
            contentsPanelHost.isHidden = !visible
            contentsDim.isHidden = !visible
        }
    }

    func load(documentID: String, completion: ((Bool) -> Void)? = nil) {
        if currentDocumentID != documentID {
            markdownSource = ""
            contentReady = false
        }
        currentDocumentID = documentID
        loadGeneration &+= 1
        let gen = loadGeneration
        spinner.startAnimating()
        progressLabel.text = "加载中…"
        loadShellIfNeeded()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = StudyDocumentStore.shared.markdownText(for: documentID)
            DispatchQueue.main.async {
                guard let self = self, gen == self.loadGeneration, self.currentDocumentID == documentID else {
                    completion?(false)
                    return
                }
                self.spinner.stopAnimating()
                guard let text = text else {
                    self.progressLabel.text = "无法打开 Markdown"
                    self.markdownSource = ""
                    self.currentDocumentID = nil
                    self.contentReady = false
                    completion?(false)
                    return
                }
                self.markdownSource = text
                self.editorView.text = text
                self.isDirty = false
                self.isPlanDocument = StudyPlanDocument.parse(text).isPlan
                self.updateBuildButtonVisibility()
                self.pendingMarkdown = text
                if self.isEditMode {
                    self.setEditMode(true)
                } else {
                    self.tryInjectPendingMarkdown()
                }
                self.updateProgressLabel()
                completion?(true)
            }
        }
    }

    func pauseReading() {
        flushMarkdownSaveIfNeeded(force: true)
        saveReadingProgressNow()
        editorView.resignFirstResponder()
    }

    func resumeAfterConversationSwitch() {
        guard contentReady else { return }
        readerSurfaceActive = true
        isRestoringViewport = true
        view.layoutIfNeeded()
        isRestoringViewport = false
        updateProgressLabel()
    }

    func prepareForShellLayoutChange() {
        guard !isShellRotating else { return }
    }

    func beginShellRotation(keeping progress: StudyProgress?) {
        shellRotationProgress = progress
        isShellRotating = true
        isRestoringViewport = true
    }

    func updateDuringShellRotation() {
        guard isShellRotating, contentReady else { return }
        if let progress = shellRotationProgress {
            applyScroll(from: progress)
        }
    }

    func finishShellRotation(using progress: StudyProgress?) {
        let snapshot = progress ?? shellRotationProgress
        isShellRotating = false
        shellRotationProgress = nil
        guard contentReady else {
            isRestoringViewport = false
            return
        }
        // Width changed — restore reading offset after layout.
        beginViewportRestore(using: snapshot)
    }

    func realignVisibleViewport(using progress: StudyProgress?) {
        guard contentReady else {
            pendingViewportProgress = progress
            return
        }
        guard readerSurfaceActive,
              webView.bounds.width > 64,
              webView.bounds.height > 64 else {
            pendingViewportProgress = progress
            return
        }
        beginViewportRestore(using: progress)
    }

    func restoreReadingProgress(_ progress: StudyProgress?) {
        realignVisibleViewport(using: progress)
    }

    private func beginViewportRestore(using progress: StudyProgress?) {
        isRestoringViewport = true
        view.layoutIfNeeded()
        applyScroll(from: progress)
        updateProgressLabel()
        isRestoringViewport = false
    }

    func captureReadingProgress() -> StudyProgress? {
        guard currentDocumentID != nil, contentReady else { return nil }
        let offset = webView.scrollView.contentOffset
        return StudyProgress(
            pageIndex: 0,
            pageOffsetY: offset.y,
            pageOffsetX: offset.x,
            anchorX: nil,
            anchorY: nil,
            scaleFactor: nil,
            updatedAt: Date()
        )
    }

    func saveReadingProgressNow() {
        progressWorkItem?.cancel()
        flushProgressSave()
    }

    func clearDocument() {
        loadGeneration &+= 1
        flushMarkdownSaveIfNeeded(force: true)
        saveReadingProgressNow()
        askPinnedEditorRange = nil
        currentDocumentID = nil
        markdownSource = ""
        editorView.text = ""
        isDirty = false
        contentReady = false
        pendingMarkdown = nil
        pendingViewportProgress = nil
        progressLabel.text = nil
        setContentsPanelVisible(false, animated: false)
        contentsVC.setHeadings([])
        guard isViewLoaded, webView != nil else { return }
        webView.evaluateJavaScript("window.__connectsRender && window.__connectsRender('');", completionHandler: nil)
    }

    func currentFullMarkdown() -> String? {
        if isEditMode { return editorView.text }
        return markdownSource.isEmpty ? nil : markdownSource
    }

    func currentPageText() -> String? {
        if isEditMode {
            let full = editorView.text ?? ""
            return full.isEmpty ? nil : String(full.prefix(4_000))
        }
        guard contentReady || !markdownSource.isEmpty else { return nil }
        return estimatedVisibleRawMarkdown()
    }

    func currentPageLabel() -> String {
        guard let id = currentDocumentID,
              let doc = StudyDocumentStore.shared.document(id: id) else { return "无文档" }
        if let path = doc.displayPath, !path.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return doc.title
    }

    @objc private func fileTitleTapped() {
        onFileTitleTapped?(progressLabel)
    }

    func captureCurrentPageImageJPEG() -> String? {
        if isEditMode { return nil }
        let bounds = webView.bounds
        guard contentReady, bounds.width > 1, bounds.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(UIScreen.main.scale, 2)
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { ctx in
            DSTheme.reader.background.setFill()
            ctx.fill(bounds)
            webView.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        return ImageAttachmentHelper.prepareJPEGBase64(from: image)
    }

    // MARK: - WK / scroll

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let href = url.absoluteString
        let isLocalImage = MarkdownPreviewAssetIndex.isPreviewAssetHref(href)
            || MarkdownStudyImporter.isStudyAssetHref(href)
            || MarkdownStudyImporter.relativeLocalImagePath(from: href) != nil
        if isLocalImage {
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
                presentStudyAsset(href: href)
                return
            }
            decisionHandler(.allow)
            return
        }
        if navigationAction.navigationType == .linkActivated {
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "http" || scheme == "https" {
                decisionHandler(.cancel)
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                return
            }
            // Non-image file / relative .md — ignore (do not silently swallow image taps).
            if scheme == "file" || scheme.isEmpty || href.lowercased().hasSuffix(".md") {
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        shellLoaded = true
        tryInjectPendingMarkdown()
    }

    private func presentStudyAsset(href: String) {
        refreshPreviewAssetCatalog()
        if let loaded = MarkdownPreviewAssetIndex.loadImage(href: href, catalog: previewAssetHandler.catalog) {
            let vc = StudyAssetImageViewController(image: loaded.image, title: loaded.title)
            present(vc, animated: true)
            return
        }

        guard let docID = currentDocumentID,
              let folder = StudyDocumentStore.shared.documentFolderURL(forID: docID) else {
            let alert = UIAlertController(title: "无法打开图片", message: "当前没有打开的文档。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            present(alert, animated: true)
            return
        }

        var candidates: [URL] = []
        if let u = MarkdownStudyImporter.assetFileURL(documentFolder: folder, href: href) {
            candidates.append(u)
        }
        if let rel = MarkdownStudyImporter.relativeLocalImagePath(from: href) {
            candidates.append(folder.appendingPathComponent(rel))
            let base = (rel as NSString).lastPathComponent
            if !base.isEmpty {
                candidates.append(folder.appendingPathComponent("assets").appendingPathComponent(base))
                candidates.append(folder.appendingPathComponent("asset").appendingPathComponent(base))
            }
        }

        var fileURL: URL?
        var data: Data?
        for url in candidates {
            if let d = try? Data(contentsOf: url), !d.isEmpty, UIImage(data: d) != nil {
                fileURL = url
                data = d
                break
            }
        }

        guard let fileURL, let data, let image = UIImage(data: data) else {
            let alert = UIAlertController(
                title: "无法打开图片",
                message: "未在同目录 ./assets 中找到该文件。\n\(href)",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "好", style: .default))
            present(alert, animated: true)
            return
        }
        let title = fileURL.deletingPathExtension().lastPathComponent
        let vc = StudyAssetImageViewController(image: image, title: title)
        present(vc, animated: true)
    }

    private func refreshPreviewAssetCatalog() {
        guard let docID = currentDocumentID,
              let folder = StudyDocumentStore.shared.documentFolderURL(forID: docID) else {
            previewAssetHandler.catalog = nil
            return
        }
        previewAssetHandler.catalog = MarkdownPreviewAssetIndex.catalog(documentFolder: folder)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "studyAsset" {
            let href: String
            if let s = message.body as? String {
                href = s
            } else {
                href = "\(message.body)"
            }
            presentStudyAsset(href: href)
            return
        }
        guard message.name == "studyReady" else { return }
        contentReady = true
        spinner.stopAnimating()
        let pending = pendingViewportProgress
        pendingViewportProgress = nil
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.beginViewportRestore(using: pending)
            self.updateProgressLabel()
            self.onPageChanged?()
            // Theme rebuild / math contain can change contentSize after the first paint.
            if pending != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.beginViewportRestore(using: pending)
                }
            }
        }
    }

    // MARK: - UIScrollViewDelegate (WKWebView scroller)

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === webView.scrollView, !isRestoringViewport, !isShellRotating else { return }
        let now = CACurrentMediaTime()
        let pct = Int((scrollFraction() * 100).rounded())
        if pct != lastProgressLabelPct, now - lastProgressLabelAt >= 0.08 {
            lastProgressLabelAt = now
            lastProgressLabelPct = pct
            updateProgressLabel()
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === webView.scrollView, !decelerate else { return }
        handleReaderScrollSettled()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === webView.scrollView else { return }
        handleReaderScrollSettled()
    }

    private func handleReaderScrollSettled() {
        lastProgressLabelPct = -1
        updateProgressLabel()
        scheduleProgressSave()
        onPageChanged?()
    }

    // MARK: - Private shell

    private func loadShellIfNeeded() {
        guard !shellLoaded else { return }
        let html = MarkdownHTMLRenderer.studyShellHTML(
            textColor: DSTheme.reader.textPrimary,
            backgroundColor: DSTheme.reader.background,
            secondaryColor: DSTheme.reader.textSecondary,
            fontSize: fontPointSize
        )
        webView.loadHTMLString(html, baseURL: MarkdownHTMLRenderer.resourceBaseURL)
    }

    private func tryInjectPendingMarkdown() {
        guard shellLoaded, let md = pendingMarkdown else { return }
        pendingMarkdown = nil
        refreshPreviewAssetCatalog()
        let rewritten = MarkdownPreviewAssetIndex.rewriteForPreview(md, catalog: previewAssetHandler.catalog)
        let js = MarkdownHTMLRenderer.renderJavaScript(content: rewritten)
        // study shell uses the same __connectsRender name
        webView.evaluateJavaScript(js) { [weak self] _, error in
            guard let self = self else { return }
            if error != nil {
                // Fallback: mark ready even if JS hiccups so capture can use raw text.
                self.contentReady = true
                self.updateProgressLabel()
            }
        }
    }

    private func applyScroll(from progress: StudyProgress?) {
        guard let progress = progress else { return }
        let y = progress.pageOffsetY ?? 0
        let x = progress.pageOffsetX ?? 0
        let scroll = webView.scrollView
        let maxY = max(scroll.contentSize.height - scroll.bounds.height, 0)
        let maxX = max(scroll.contentSize.width - scroll.bounds.width, 0)
        scroll.contentOffset = CGPoint(
            x: min(max(x, 0), maxX),
            y: min(max(y, 0), maxY)
        )
    }

    private func scrollFraction() -> CGFloat {
        let scroll = webView.scrollView
        let maxY = max(scroll.contentSize.height - scroll.bounds.height, 1)
        return min(max(scroll.contentOffset.y / maxY, 0), 1)
    }

    private func estimatedVisibleRawMarkdown() -> String {
        let full = markdownSource
        guard !full.isEmpty else { return "" }
        let maxLen = 4000
        if full.count <= maxLen { return full }
        let ratio = Double(scrollFraction())
        let start = max(0, Int(Double(full.count) * ratio) - maxLen / 5)
        let end = min(full.count, start + maxLen)
        let startIdx = full.index(full.startIndex, offsetBy: start)
        let endIdx = full.index(full.startIndex, offsetBy: end)
        return String(full[startIdx..<endIdx])
    }

    private func updateProgressLabel() {
        let name = currentPageLabel()
        progressLabel.text = name == "无文档" ? name : "\(name) ▾"
    }

    private func scheduleProgressSave() {
        guard currentDocumentID != nil, contentReady else { return }
        progressWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushProgressSave()
        }
        progressWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func flushProgressSave() {
        guard let documentID = currentDocumentID,
              let progress = captureReadingProgress() else { return }
        StudyProgressStore.shared.update(documentID: documentID, progress: progress)
    }

#if DEBUG
    func debugWebContentReady() -> Bool { contentReady }
    func debugWebScrollOffsetY() -> CGFloat { webView.scrollView.contentOffset.y }
    func debugWebContentHeight() -> CGFloat { webView.scrollView.contentSize.height }
    func debugScrollWeb(by dy: CGFloat, animated: Bool) {
        let scroll = webView.scrollView
        let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
        let y = min(max(0, scroll.contentOffset.y + dy), maxY)
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: animated)
        scroll.layoutIfNeeded()
    }
    /// True when document CSS uses overflow scroll/auto (expected for WK-owned scrolling).
    func debugProbeNestedDocumentScroll(completion: @escaping (Bool) -> Void) {
        let js = """
        (function(){
          var se = document.scrollingElement || document.documentElement;
          var body = document.body;
          var ov = window.getComputedStyle(body).overflow + '|' + window.getComputedStyle(document.documentElement).overflow;
          return JSON.stringify({
            scrollTop: se.scrollTop||0,
            bodyOverflow: ov,
            scrollHeight: se.scrollHeight||0,
            clientHeight: se.clientHeight||0
          });
        })();
        """
        webView.evaluateJavaScript(js) { result, _ in
            guard let raw = result as? String,
                  let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(false)
                return
            }
            let overflow = (obj["bodyOverflow"] as? String) ?? ""
            let nestedCSS = overflow.contains("auto") || overflow.contains("scroll")
            completion(nestedCSS)
        }
    }
#endif
}
