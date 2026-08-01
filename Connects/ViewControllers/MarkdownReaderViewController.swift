import UIKit
import WebKit

/// Study-mode Markdown reader — same shell role as `PDFReaderViewController`.
final class MarkdownReaderViewController: UIViewController, WKNavigationDelegate, WKScriptMessageHandler, UITextViewDelegate, UIScrollViewDelegate {
    private let topBar = UIView()
    private let sidebarButton = UIButton(type: .system)
    private let contentsButton = UIButton(type: .system)
    private let modeButton = UIButton(type: .system)
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
    private var contentsPanelWidth: NSLayoutConstraint!
    private var contentsPanelTrailing: NSLayoutConstraint!
    private var isContentsPanelVisible = false
    private let contentsPanelWidthConstant: CGFloat = 220
    private var shellLoaded = false
    private var pendingMarkdown: String?
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

    var onPageChanged: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onAskSelection: ((String) -> Void)?

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
                    .foregroundColor: DSTheme.c.textPrimary
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
            .foregroundColor: DSTheme.c.textPrimary
        ]
        let mutable = NSMutableAttributedString(string: plain, attributes: attrs)
        if let pinned = askPinnedEditorRange {
            let clamped = NSIntersectionRange(pinned, NSRange(location: 0, length: (plain as NSString).length))
            if clamped.length > 0 {
                mutable.addAttribute(
                    .backgroundColor,
                    value: DSTheme.c.accent.withAlphaComponent(0.28),
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
        sidebarButtonWidthConstraint = sidebarButton.widthAnchor.constraint(equalToConstant: 40)

        contentsButton.translatesAutoresizingMaskIntoConstraints = false
        contentsButton.setImage(ActionIconFactory.image(.toc, pointSize: 18), for: .normal)
        contentsButton.tintColor = DSTheme.c.textSecondary
        contentsButton.accessibilityLabel = "目录"
        contentsButton.addTarget(self, action: #selector(contentsTapped), for: .touchUpInside)
        topBar.addSubview(contentsButton)

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
        saveButton.isEnabled = false
        saveButton.alpha = 0.35
        topBar.addSubview(saveButton)

        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        progressLabel.textColor = DSTheme.c.textSecondary
        progressLabel.textAlignment = .center
        progressLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        topBar.addSubview(progressLabel)

        let controller = WKUserContentController()
        controller.add(WeakScriptMessageHandler(delegate: self), name: "studyReady")
        controller.add(WeakScriptMessageHandler(delegate: self), name: "studyAsset")
        let config = ConnectsWebKit.makeConfiguration(userContentController: controller)

        webView = StudyAskWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        ConnectsWebKit.applyReadingSurfaceTuning(webView, background: DSTheme.c.background)
        webView.scrollView.delegate = self
        webView.onAskSelection = { [weak self] text in
            self?.onAskSelection?(text)
        }
        view.addSubview(webView)

        editorView.translatesAutoresizingMaskIntoConstraints = false
        editorView.font = UIFont(name: "Menlo-Regular", size: 14) ?? UIFont.systemFont(ofSize: 14)
        editorView.backgroundColor = DSTheme.c.background
        editorView.textColor = DSTheme.c.textPrimary
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
            topBar.heightAnchor.constraint(equalToConstant: 40),

            sidebarButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 4),
            sidebarButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            sidebarButtonWidthConstraint,
            sidebarButton.heightAnchor.constraint(equalToConstant: 40),

            progressLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            progressLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            progressLabel.leadingAnchor.constraint(greaterThanOrEqualTo: sidebarButton.trailingAnchor, constant: 4),
            progressLabel.trailingAnchor.constraint(lessThanOrEqualTo: modeButton.leadingAnchor, constant: -4),

            modeButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -2),
            modeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            modeButton.widthAnchor.constraint(equalToConstant: 40),
            modeButton.heightAnchor.constraint(equalToConstant: 40),

            saveButton.trailingAnchor.constraint(equalTo: contentsButton.leadingAnchor, constant: -2),
            saveButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            saveButton.widthAnchor.constraint(equalToConstant: 40),
            saveButton.heightAnchor.constraint(equalToConstant: 40),

            contentsButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -4),
            contentsButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            contentsButton.widthAnchor.constraint(equalToConstant: 40),
            contentsButton.heightAnchor.constraint(equalToConstant: 40),

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
        sidebarButton.setImage(ActionIconFactory.image(kind, pointSize: 18), for: .normal)
        sidebarButton.tintColor = DSTheme.c.textSecondary
        sidebarButton.accessibilityLabel = collapsed ? "打开侧栏" : "关闭侧栏"
    }

    func setSidebarButtonHidden(_ hidden: Bool) {
        sidebarButton.isHidden = hidden
        sidebarButtonWidthConstraint.constant = hidden ? 0 : 40
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

    @objc private func themeChanged() {
        view.backgroundColor = DSTheme.c.background
        topBar.backgroundColor = DSTheme.c.background
        ConnectsWebKit.applyReadingSurfaceTuning(webView, background: DSTheme.c.background)
        webView.scrollView.delegate = self
        editorView.backgroundColor = DSTheme.c.background
        editorView.textColor = DSTheme.c.textPrimary
        progressLabel.textColor = DSTheme.c.textSecondary
        sidebarButton.tintColor = DSTheme.c.textSecondary
        contentsButton.tintColor = DSTheme.c.textSecondary
        refreshModeChrome()
        contentsPanelHost.backgroundColor = DSTheme.c.background
        contentsPanelHost.layer.borderColor = DSTheme.c.border.cgColor
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

    private func setEditMode(_ editing: Bool) {
        isEditMode = editing
        refreshModeChrome()
        contentsButton.isHidden = editing
        webView.isHidden = editing
        editorView.isHidden = !editing
        if editing {
            editorView.text = markdownSource
            editorView.becomeFirstResponder()
        } else {
            editorView.resignFirstResponder()
            pendingMarkdown = markdownSource
            tryInjectPendingMarkdown()
            refreshContentsPanel()
        }
        updateProgressLabel()
    }

    private func refreshModeChrome() {
        let c = DSTheme.c
        let modeKind: ActionIconFactory.Kind = isEditMode ? .readMode : .editMode
        modeButton.setTitle(nil, for: .normal)
        modeButton.setImage(ActionIconFactory.image(modeKind, pointSize: 18), for: .normal)
        modeButton.tintColor = c.textSecondary
        modeButton.accessibilityLabel = isEditMode ? "切换到阅读模式" : "切换到编辑模式"
        saveButton.setTitle(nil, for: .normal)
        saveButton.setImage(ActionIconFactory.image(.save, pointSize: 18), for: .normal)
        saveButton.isHidden = false
        saveButton.isEnabled = isEditMode
        saveButton.alpha = isEditMode ? 1 : 0.35
        saveButton.tintColor = isEditMode ? c.accent : c.textTertiary
        saveButton.accessibilityLabel = "保存"
    }

    /// Keyboard shortcut: enter Markdown edit mode and focus the editor.
    func focusForKeyboardEditing() {
        if !isEditMode {
            setEditMode(true)
        } else {
            _ = editorView.becomeFirstResponder()
        }
    }

    var isMarkdownEditorFirstResponder: Bool {
        isEditMode && editorView.isFirstResponder
    }

    func saveFromKeyboardShortcut() {
        flushMarkdownSaveIfNeeded(force: true)
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
        contentsPanelHost.backgroundColor = DSTheme.c.background
        contentsPanelHost.layer.shadowColor = UIColor.black.cgColor
        contentsPanelHost.layer.shadowOpacity = 0.12
        contentsPanelHost.layer.shadowRadius = 8
        contentsPanelHost.layer.shadowOffset = CGSize(width: -2, height: 0)
        contentsPanelHost.layer.borderWidth = 1.0 / UIScreen.main.scale
        contentsPanelHost.layer.borderColor = DSTheme.c.border.cgColor
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
        guard currentDocumentID != nil else { return "无文档" }
        if isEditMode {
            let dirty = isDirty ? " · 未保存" : ""
            return "Markdown 编辑\(dirty)"
        }
        guard contentReady else { return "无文档" }
        let pct = Int((scrollFraction() * 100).rounded())
        return "Markdown · \(pct)%"
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
            DSTheme.c.background.setFill()
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
        // Any Study image target (connects.local / relative png / file URL ending in image).
        if MarkdownStudyImporter.isStudyAssetHref(href)
            || MarkdownStudyImporter.relativeLocalImagePath(from: href) != nil {
            decisionHandler(.cancel)
            let pass = MarkdownStudyImporter.relativeLocalImagePath(from: href) ?? href
            presentStudyAsset(href: pass)
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
            // Also try basename-only under assets/
            let base = (rel as NSString).lastPathComponent
            if !base.isEmpty {
                candidates.append(folder.appendingPathComponent("assets").appendingPathComponent(base))
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
                message: "资源不在文档目录中。\n\(href)\n\n请删除后重新导入 Markdown（需能读到旁路图片文件）。",
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
            textColor: DSTheme.c.textPrimary,
            backgroundColor: DSTheme.c.background,
            secondaryColor: DSTheme.c.textSecondary,
            fontSize: 17
        )
        webView.loadHTMLString(html, baseURL: MarkdownHTMLRenderer.resourceBaseURL)
    }

    private func tryInjectPendingMarkdown() {
        guard shellLoaded, let md = pendingMarkdown else { return }
        pendingMarkdown = nil
        let js = MarkdownHTMLRenderer.renderJavaScript(content: md)
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
        progressLabel.text = currentPageLabel()
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
