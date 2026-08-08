import UIKit
import WebKit
import OSLog
import ReadiumShared
import ReadiumNavigator

/// Step-by-step record of one sidebar annotation jump.
///
/// The jump path has many places where it can legitimately stop, and from the
/// outside every one of them looks identical: the page simply does not move.
/// Recording each step turns "跳转没反应" into something readable in Console.
private struct AnnotationJumpTrace {
    private static let log = Logger(subsystem: "com.connects.reader", category: "annotation-jump")

    private let annotationID: String
    private var steps: [String] = []
    private var outcome = "unfinished"

    init(annotationID: String) {
        self.annotationID = annotationID
    }

    mutating func note(_ step: String) {
        steps.append(step)
    }

    mutating func href(_ original: String, resolvedTo repaired: String?) {
        if let repaired, repaired != original {
            steps.append("href=\(original) NOT in readingOrder, repaired to \(repaired)")
        } else if repaired == nil {
            steps.append("href=\(original) NOT in readingOrder, no match")
        } else {
            steps.append("href=\(original) ok")
        }
    }

    mutating func go(_ label: String, progression: Double?, accepted: Bool) {
        let value = progression.map { String(format: "%.5f", $0) } ?? "nil"
        steps.append("go(\(label), prog=\(value)) accepted=\(accepted)")
    }

    mutating func measured(_ label: String, _ m: EbookReaderViewController.AnnotationMeasure) {
        if let error = m.error {
            steps.append("measure(\(label)) FAILED: \(error)")
            return
        }
        let page = m.page.map(String.init) ?? "?"
        let current = m.currentPage.map(String.init) ?? "?"
        let total = m.pages.map(String.init) ?? "?"
        steps.append(String(
            format: "measure(%@) prog=%.5f visible=%@ approx=%@ page=%@ of %@ (on screen: %@)",
            label, m.progression, m.visible ? "yes" : "no", m.approx ? "yes" : "no",
            page, total, current
        ))
    }

    mutating func painted(_ label: String, sent: Int, attached: Int) {
        steps.append("paint(\(label)) sent=\(sent) attached=\(attached)")
    }

    mutating func location(_ locator: Locator?) {
        guard let locator else {
            steps.append("currentLocation=nil")
            return
        }
        let prog = locator.locations.progression.map { String(format: "%.5f", $0) } ?? "nil"
        steps.append("currentLocation \(locator.href.string) prog=\(prog)")
    }

    mutating func finish(_ outcome: String) {
        self.outcome = outcome
    }

    func emit() {
        Self.log.info("""
        jump \(annotationID, privacy: .public) -> \(outcome, privacy: .public)
        \(steps.joined(separator: "\n  "), privacy: .public)
        """)
    }
}

/// Study ebook shell: EPUB via Readium navigator. MOBI/AZW deferred.
final class EbookReaderViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, EPUBNavigatorDelegate {
    private let topBar = UIView()
    private let topBarSeparator = UIView()
    private let sidebarButton = UIButton(type: .system)
    private let contentsButton = UIButton(type: .system)
    private let appearanceButton = UIButton(type: .system)
    private let fileTitleButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let contentHost = UIView()
    private let contentsPanelHost = UIView()
    private let contentsDim = UIControl()
    private let contentsHeader = UIView()
    private let contentsTitleButton = UIButton(type: .system)
    private let contentsTable = UITableView(frame: .zero, style: .plain)

    private var sidebarButtonWidthConstraint: NSLayoutConstraint!
    private var contentsPanelWidth: NSLayoutConstraint!
    private var contentsPanelTrailing: NSLayoutConstraint!
    private var isContentsPanelVisible = false
    private let contentsPanelWidthConstant: CGFloat = 240
    private var contentsPanelTab: ContentsPanelTab = .outline

    private var currentDocumentID: String?
    private var documentDisplayTitle = ""
    private var loadGeneration: UInt = 0
    private var engineKind: EngineKind = .none
    private var readerSurfaceActive = true
    private var progressWorkItem: DispatchWorkItem?
    private var pinchStartFontSize: CGFloat = 18
    private var pinchTargetFontSize: CGFloat = 18
    private var isFontPinching = false
    private var skipNextFontSizePreferenceApply = false
    private let fontSizeHUD = UILabel()
    private var fontSizeHUDHideWork: DispatchWorkItem?
    /// WKUserContentController retains handlers strongly — keep a weak proxy.
    private lazy var fontPinchScriptProxy = FontPinchScriptProxy(owner: self)
    private lazy var highlightScriptProxy = HighlightScriptProxy(owner: self)

    // EPUB
    private var publication: Publication?
    private var epubNavigator: EPUBNavigatorViewController?
    private var sourceEPUBURL: URL?
    /// Live `ConnectsEPUB/cached-*.epub` the navigator is serving — must stay pinned.
    private var openedCacheURL: URL?
    private var lastLocatorJSON: String?
    private var tocLinks: [Link] = []
    private var epubAnnotations: [ReadingAnnotation] = []
    private var pendingSelection: Selection?
    private var pendingLocatorJSON: String?
    private var pendingQuote: String?
    private var pendingAnchorFrame: CGRect?
    private var highlightPickerOverlay: UIView?
    /// Full-screen (navigator) tap catcher behind the color bar.
    private var highlightPickerDim: UIControl?
    private var selectionPickerWork: DispatchWorkItem?
    /// True while committing a highlight (ignore selection-dismiss races).
    private var isCommittingHighlight = false
    /// Cancels overlapping jump-related work.
    private var markRestoreTask: Task<Void, Never>?
    /// Client rects of the last selection (webview viewport coords) for picker chrome.
    private var pendingSelectionRects: [CGRect] = []
    private var pendingSelectionScroll: CGPoint = .zero
    /// Cached `Publication.positions()` count for title chrome (`第 N / M 页`).
    private var epubPositionCount: Int = 0
    private var directionalNavAdapter: DirectionalNavigationAdapter?
    private var didKickEPUBLayout = false
    /// Waits until Readium reports the first real page location (not just navigator construction).
    private var firstEPUBLocationContinuation: CheckedContinuation<Bool, Never>?
    private var waitingForFirstEPUBLocation = false
    private var sawEPUBLocationEvent = false


    private enum EngineKind {
        case none
        case epub
    }

    private enum ContentsPanelTab: Int, CaseIterable {
        case outline = 0
        case annotations = 1

        var title: String {
            switch self {
            case .outline: return "目录"
            case .annotations: return "标注"
            }
        }

        var next: ContentsPanelTab {
            let all = ContentsPanelTab.allCases
            return all[(rawValue + 1) % all.count]
        }
    }

    var onPageChanged: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onFileTitleTapped: ((UIView) -> Void)?

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DSTheme.c.background
        buildChrome()
        NotificationCenter.default.addObserver(
            self, selector: #selector(systemThemeChanged), name: .themeDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(readerThemeChanged), name: .readerThemeDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(fontSizeSettingChanged), name: .ebookReaderFontSizeDidChange, object: nil
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Recover if a prior pinch left swipe page-turns disabled.
        if !isFontPinching {
            setEPUBPageTurnsEnabled(true)
        }
    }

    private func buildChrome() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.backgroundColor = DSTheme.c.background
        topBar.isOpaque = true
        view.addSubview(topBar)

        topBarSeparator.translatesAutoresizingMaskIntoConstraints = false
        topBarSeparator.backgroundColor = DSTheme.c.border.withAlphaComponent(0.55)
        view.addSubview(topBarSeparator)

        sidebarButton.translatesAutoresizingMaskIntoConstraints = false
        sidebarButton.addTarget(self, action: #selector(sidebarTapped), for: .touchUpInside)
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

        fileTitleButton.translatesAutoresizingMaskIntoConstraints = false
        fileTitleButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        fileTitleButton.titleLabel?.lineBreakMode = .byTruncatingMiddle
        fileTitleButton.setTitleColor(DSTheme.c.textPrimary, for: .normal)
        fileTitleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fileTitleButton.addTarget(self, action: #selector(fileTitleTapped), for: .touchUpInside)
        topBar.addSubview(fileTitleButton)

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.backgroundColor = DSTheme.reader.background
        contentHost.clipsToBounds = true
        view.addSubview(contentHost)
        // Font pinch is injected into WK (setupUserScripts). Do not add a native
        // UIPinchGestureRecognizer here — it steals touches and evaluateJavaScript
        // is deferred until fingers lift.

        fontSizeHUD.translatesAutoresizingMaskIntoConstraints = false
        fontSizeHUD.font = UIFont.monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        fontSizeHUD.textColor = .white
        fontSizeHUD.textAlignment = .center
        fontSizeHUD.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        fontSizeHUD.layer.cornerRadius = 12
        fontSizeHUD.clipsToBounds = true
        fontSizeHUD.isHidden = true
        fontSizeHUD.alpha = 0
        view.addSubview(fontSizeHUD)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        contentsDim.translatesAutoresizingMaskIntoConstraints = false
        contentsDim.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        contentsDim.addTarget(self, action: #selector(hideContentsPanel), for: .touchUpInside)
        contentsDim.isHidden = true
        view.addSubview(contentsDim)

        contentsPanelHost.translatesAutoresizingMaskIntoConstraints = false
        contentsPanelHost.backgroundColor = DSTheme.c.surface
        view.addSubview(contentsPanelHost)

        contentsHeader.translatesAutoresizingMaskIntoConstraints = false
        contentsPanelHost.addSubview(contentsHeader)

        contentsTitleButton.translatesAutoresizingMaskIntoConstraints = false
        contentsTitleButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        contentsTitleButton.contentHorizontalAlignment = .leading
        contentsTitleButton.addTarget(self, action: #selector(contentsSwitchTapped), for: .touchUpInside)
        contentsTitleButton.accessibilityHint = "点按切换目录与标注"
        contentsHeader.addSubview(contentsTitleButton)
        refreshContentsPanelChrome()

        contentsTable.translatesAutoresizingMaskIntoConstraints = false
        contentsTable.dataSource = self
        contentsTable.delegate = self
        contentsTable.allowsSelection = true
        contentsTable.register(UITableViewCell.self, forCellReuseIdentifier: "ch")
        contentsTable.rowHeight = UITableView.automaticDimension
        contentsTable.estimatedRowHeight = 36
        contentsTable.backgroundColor = DSTheme.c.surface
        contentsPanelHost.addSubview(contentsTable)

        contentsPanelWidth = contentsPanelHost.widthAnchor.constraint(equalToConstant: contentsPanelWidthConstant)
        contentsPanelTrailing = contentsPanelHost.trailingAnchor.constraint(
            equalTo: view.trailingAnchor,
            constant: contentsPanelWidthConstant
        )

        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),

            topBarSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBarSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBarSeparator.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            topBarSeparator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            sidebarButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 4),
            sidebarButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            sidebarButtonWidthConstraint,
            sidebarButton.heightAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),

            fileTitleButton.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            fileTitleButton.topAnchor.constraint(equalTo: topBar.topAnchor),
            fileTitleButton.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            fileTitleButton.leadingAnchor.constraint(greaterThanOrEqualTo: sidebarButton.trailingAnchor, constant: 4),
            fileTitleButton.trailingAnchor.constraint(lessThanOrEqualTo: appearanceButton.leadingAnchor, constant: -4),

            contentsButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -4),
            contentsButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            contentsButton.widthAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),
            contentsButton.heightAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),

            appearanceButton.trailingAnchor.constraint(equalTo: contentsButton.leadingAnchor, constant: -2),
            appearanceButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            appearanceButton.widthAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),
            appearanceButton.heightAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),

            contentHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: topBarSeparator.bottomAnchor),
            contentHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            contentsDim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentsDim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentsDim.topAnchor.constraint(equalTo: topBarSeparator.bottomAnchor),
            contentsDim.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentsPanelHost.topAnchor.constraint(equalTo: topBarSeparator.bottomAnchor),
            contentsPanelHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentsPanelWidth,
            contentsPanelTrailing,

            contentsHeader.leadingAnchor.constraint(equalTo: contentsPanelHost.leadingAnchor),
            contentsHeader.trailingAnchor.constraint(equalTo: contentsPanelHost.trailingAnchor),
            contentsHeader.topAnchor.constraint(equalTo: contentsPanelHost.topAnchor),
            contentsHeader.heightAnchor.constraint(equalToConstant: 40),

            contentsTitleButton.leadingAnchor.constraint(equalTo: contentsHeader.leadingAnchor, constant: 12),
            contentsTitleButton.trailingAnchor.constraint(equalTo: contentsHeader.trailingAnchor, constant: -12),
            contentsTitleButton.centerYAnchor.constraint(equalTo: contentsHeader.centerYAnchor),
            contentsTitleButton.heightAnchor.constraint(equalToConstant: 32),

            contentsTable.leadingAnchor.constraint(equalTo: contentsPanelHost.leadingAnchor),
            contentsTable.trailingAnchor.constraint(equalTo: contentsPanelHost.trailingAnchor),
            contentsTable.topAnchor.constraint(equalTo: contentsHeader.bottomAnchor),
            contentsTable.bottomAnchor.constraint(equalTo: contentsPanelHost.bottomAnchor),

            fontSizeHUD.centerXAnchor.constraint(equalTo: contentHost.centerXAnchor),
            fontSizeHUD.centerYAnchor.constraint(equalTo: contentHost.centerYAnchor),
            fontSizeHUD.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            fontSizeHUD.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    // MARK: - Public Study surface

    /// Top hugs Study chrome (contentHost is already below the top bar — do NOT
    /// re-apply window safeArea.top or pages look empty under the title).
    /// Bottom clears floating ▲▼ chip + home-indicator band.
    private static var readingContentInsets: (top: CGFloat, bottom: CGFloat) {
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        let handleInset: CGFloat = phone ? 18 : 12
        let chip = StudyPanelStageCapsule.chipHeight
        return (
            top: 0,
            bottom: chip + handleInset + 16
        )
    }

    func setReaderSurfaceActive(_ active: Bool) { readerSurfaceActive = active }
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

    func updateSidebarToggle(collapsed: Bool) {
        let kind: ActionIconFactory.Kind = collapsed ? .sidebar : .sidebarOpen
        sidebarButton.setImage(ActionIconFactory.image(kind, pointSize: ActionIconFactory.chromeGlyph), for: .normal)
        sidebarButton.tintColor = DSTheme.c.textSecondary
        sidebarButton.accessibilityLabel = collapsed ? "打开侧栏" : "关闭侧栏"
    }
    func prepareForShellLayoutChange() {}
    func beginShellRotation(keeping progress: StudyProgress?) {}
    func updateDuringShellRotation() {}
    func finishShellRotation(using progress: StudyProgress?) {
        if let progress { realignVisibleViewport(using: progress) }
    }
    func realignVisibleViewport(using progress: StudyProgress?) {
        guard let progress else { return }
        if let json = progress.ebookLocatorJSON, !json.isEmpty {
            restoreLocator(json: json)
        }
    }
    func resumeAfterConversationSwitch() { readerSurfaceActive = true }
    func pauseReading() {
        saveReadingProgressNow()
        flushAnnotationsToPackage()
    }

    func saveReadingProgressNow() {
        guard let id = currentDocumentID else { return }
        let json: String? = {
            switch engineKind {
            case .epub:
                return epubNavigator?.currentLocation.flatMap { try? $0.jsonString() } ?? lastLocatorJSON
            case .none:
                return nil
            }
        }()
        var progress = StudyProgress(
            pageIndex: 0,
            pageOffsetY: 0,
            scaleFactor: SettingsManager.shared.ebookReaderFontSize,
            updatedAt: Date()
        )
        progress.ebookLocatorJSON = json
        StudyProgressStore.shared.update(documentID: id, progress: progress)
    }

    func captureReadingProgress() -> StudyProgress? {
        guard currentDocumentID != nil else { return nil }
        let json: String? = {
            switch engineKind {
            case .epub:
                return epubNavigator?.currentLocation.flatMap { try? $0.jsonString() } ?? lastLocatorJSON
            case .none:
                return nil
            }
        }()
        var p = StudyProgress(
            pageIndex: 0,
            pageOffsetY: 0,
            scaleFactor: SettingsManager.shared.ebookReaderFontSize
        )
        p.ebookLocatorJSON = json
        return p
    }

    func currentPageLabel() -> String {
        if engineKind == .epub, let loc = epubNavigator?.currentLocation {
            let total = epubPositionCount
            if let pos = loc.locations.position, pos > 0 {
                if total > 0 {
                    return "第 \(pos) / \(total) 页"
                }
                return "第 \(pos) 页"
            }
            // totalProgression is (position - 1) / total → page = floor(prog * total) + 1
            if let prog = loc.locations.totalProgression, prog >= 0, total > 0 {
                let derived = min(total, max(1, Int(floor(prog * Double(total))) + 1))
                return "第 \(derived) / \(total) 页"
            }
            if let prog = loc.locations.totalProgression, prog >= 0 {
                return String(format: "%.0f%%", prog * 100)
            }
        }
        return ""
    }

    func captureCurrentPageImageJPEG() -> String? {
        let target = epubNavigator?.view ?? contentHost
        let bounds = target.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { _ in
            target.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        return ImageAttachmentHelper.prepareJPEGBase64(from: image)
    }

    func isLoaded(documentID: String) -> Bool {
        currentDocumentID == documentID && engineKind != .none
    }

    func clearDocument() {
        saveReadingProgressNow()
        teardownEngines()
        currentDocumentID = nil
        documentDisplayTitle = ""
        fileTitleButton.setTitle(nil, for: .normal)
    }

    func load(documentID: String, completion: ((Bool) -> Void)? = nil) {
        if isLoaded(documentID: documentID) {
            completion?(true)
            return
        }
        clearDocument()
        currentDocumentID = documentID
        loadGeneration &+= 1
        let gen = loadGeneration
        spinner.startAnimating()
        fileTitleButton.setTitle("加载中…", for: .normal)

        Task { @MainActor in
            do {
                let url = try StudyDocumentStore.shared.resolvedURL(forID: documentID)
                let title = StudyDocumentStore.shared.document(id: documentID)?.title
                    ?? url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension.lowercased()
                let saved = StudyProgressStore.shared.progress(for: documentID)
                if let scale = saved?.scaleFactor, scale >= 14, scale <= 28 {
                    SettingsManager.shared.ebookReaderFontSize = SettingsManager.snapEbookFontSize(scale)
                }
                guard gen == self.loadGeneration, self.currentDocumentID == documentID else {
                    completion?(false)
                    return
                }
                self.documentDisplayTitle = title
                await self.waitForReadableContentHostSize()
                guard gen == self.loadGeneration, self.currentDocumentID == documentID else {
                    completion?(false)
                    return
                }
                if ext == "epub" {
                    try await self.openEPUB(url: url, restoreJSON: saved?.ebookLocatorJSON)
                    guard gen == self.loadGeneration, self.currentDocumentID == documentID else {
                        completion?(false)
                        return
                    }
                    self.spinner.stopAnimating()
                    self.refreshTitleChrome()
                    completion?(true)
                } else if ext == "mobi" || ext == "azw3" || ext == "azw" {
                    throw StudyDocumentError.unsupportedMobiFormat
                } else {
                    throw StudyDocumentError.invalidEbook
                }
            } catch {
                self.spinner.stopAnimating()
                self.fileTitleButton.setTitle("无法打开电子书", for: .normal)
                self.currentDocumentID = nil
                self.teardownEngines()
                ConnectsToast.show(error.localizedDescription, in: self.view, duration: 2.0)
                completion?(false)
            }
        }
    }

    // MARK: - Engines

    @MainActor
    private func openEPUB(url: URL, restoreJSON: String?) async throws {
        do {
            try await openEPUBOnce(url: url, restoreJSON: restoreJSON)
        } catch {
            guard restoreJSON != nil else { throw error }
            // Corrupt Foliate / foreign locator often leaves Readium spinning forever,
            // so fall back to the start for this session. The saved locator stays put:
            // discarding it on one bad open is how a reader silently loses its place.
            try await openEPUBOnce(url: url, restoreJSON: nil)
        }
    }

    @MainActor
    private func openEPUBOnce(url: URL, restoreJSON: String?) async throws {
        teardownEngines()
        engineKind = .epub
        didKickEPUBLayout = false
        sawEPUBLocationEvent = false

        let opened = try await ReadiumEbookOpener.openEPUB(at: url)
        let pub = opened.publication
        guard !pub.readingOrder.isEmpty else {
            ReadiumEbookOpener.releaseCache(opened.cacheURL)
            throw ReadiumEbookError.openFailed("EPUB 阅读顺序为空")
        }
        publication = pub
        openedCacheURL = opened.cacheURL
        sourceEPUBURL = opened.sourceURL

        await waitForReadableContentHostSize()

        let initial = validatedRestoreLocator(restoreJSON, in: pub)

        // Arm before embedding — first locationDidChange can fire during initialize().
        waitingForFirstEPUBLocation = true

        var config = EPUBNavigatorViewController.Configuration(
            // Keep previous warm (adjacent chapter for .end landing); next can stay warmer.
            preloadPreviousPositionCount: 4,
            preloadNextPositionCount: 6
        )
        config.preferences = makeEPUBPreferences()
        config.defaults = EPUBDefaults(pageMargins: 0.85, scroll: false, spread: .never)
        config.editingActions = EditingAction.defaultActions + [
            EditingAction(title: "浅蓝高亮", action: #selector(highlightSelectionBlue)),
            EditingAction(title: "浅绿高亮", action: #selector(highlightSelectionGreen)),
        ]
        // Soft highlight wash + activable taps (TestApp path). Preview EPUB cache is
        // separate from source — decorations are runtime-only on the live WK document.
        config.decorationTemplates = HTMLDecorationTemplate.defaultTemplates(
            defaultTint: ReadingAnnotationStyle.epubDot(.blue),
            lineWeight: 2,
            cornerRadius: 2,
            alpha: 0.32,
            experimentalPositioning: false
        )
        // Study top bar already provides chrome — hug it at the top.
        // Bottom must clear the floating ▲▼ stage chip on both iPhone and iPad.
        let insets = Self.readingContentInsets
        config.contentInset = [
            .compact: insets,
            .regular: insets,
        ]
        // Wide enough for iPad, but keep a readable side gutter (not edge-to-edge).
        // Page colors live in USER preferences only — do not bake open-time
        // night/day into --RS__* or theme toggles only repaint chrome.
        config.readiumCSSRSProperties = CSSRSProperties(
            pageGutter: CSSPxLength(22),
            maxLineLength: CSSRemLength(100)
        )

        let nav = try EPUBNavigatorViewController(
            publication: pub,
            initialLocation: initial,
            config: config
        )
        nav.delegate = self
        let adapter = DirectionalNavigationAdapter()
        adapter.bind(to: nav)
        directionalNavAdapter = adapter
        epubNavigator = nav
        epubAnnotations = EPUBAnnotationStore.load(epubURL: opened.sourceURL, documentID: currentDocumentID)
        deletedAnnotationIDs = EPUBAnnotationStore.loadDeletedIDs(
            epubURL: opened.sourceURL,
            documentID: currentDocumentID
        )
        // Wait for the first spread to paint — the painter needs a laid-out body.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard self.epubNavigator === nav else { return }
            await self.syncAnnotationsToPage()
        }

        addChild(nav)
        // Match AI chat surface — not pure white / pure black Readium defaults.
        let pageBG = DSTheme.reader.background
        nav.view.backgroundColor = pageBG
        contentHost.backgroundColor = pageBG
        var frame = contentHost.bounds
        if frame.width <= 32 || frame.height <= 32 {
            frame = CGRect(
                x: 0,
                y: 0,
                width: max(view.bounds.width, 390),
                height: max(view.bounds.height - 52, 700)
            )
        }
        nav.view.frame = frame
        nav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentHost.addSubview(nav.view)
        contentHost.layoutIfNeeded()
        if contentHost.bounds.width > 32, contentHost.bounds.height > 32 {
            nav.view.frame = contentHost.bounds
        }
        nav.view.setNeedsLayout()
        nav.view.layoutIfNeeded()
        nav.didMove(toParent: self)
        lastLocatorJSON = (initial != nil) ? restoreJSON : nil
        didKickEPUBLayout = true

        // Stop shell spinner immediately — long "加载中…" was just paint-wait, not open.
        spinner.stopAnimating()
        refreshTitleChrome()

        Task { @MainActor [weak self] in
            guard let self, self.publication === pub else { return }
            let toc = await pub.tableOfContents().getOrNil() ?? []
            self.tocLinks = self.flattenTOC(toc)
            self.contentsTable.reloadData()
            let positions = await pub.positions().getOrNil() ?? []
            guard self.publication === pub else { return }
            self.epubPositionCount = positions.count
            self.refreshTitleChrome()
        }

        // Kick layout as soon as the host has a size — no fixed 250ms sleep.
        if contentHost.bounds.width > 32 {
            nav.view.frame = contentHost.bounds
        }
        nav.view.setNeedsLayout()
        nav.view.layoutIfNeeded()
        // Triggers viewWillAppear → viewSizeWillChange (needed when embedded in Study).
        nav.beginAppearanceTransition(true, animated: false)
        nav.endAppearanceTransition()

        if let initial {
            // One `go` is not enough on a cold open: the spread may still be
            // laying out, and a dropped restore silently drops the reader at the
            // front of the book.
            var restored = false
            for attempt in 0 ..< 4 {
                if await nav.go(to: initial, options: NavigatorGoOptions(animated: false)) == true {
                    restored = true
                    break
                }
                try? await Task.sleep(nanoseconds: UInt64(100 + attempt * 80) * 1_000_000)
            }
            if !restored, let first = pub.readingOrder.first {
                _ = await nav.go(to: first)
            }
        } else if let first = pub.readingOrder.first {
            _ = await nav.go(to: first)
        }

        // Soft wait for first paint signal only — never snapshot the hierarchy
        // (drawHierarchy every tick made cold open feel stuck).
        _ = await waitForEPUBPainted(timeoutNanoseconds: 1_200_000_000)
        waitingForFirstEPUBLocation = false
        firstEPUBLocationContinuation = nil
        // Preferences already applied via config — do not submitPreferences again
        // (that reloads spreads and doubles open time).
        applyChromeColors()
        applyPageSurfaceColors()
        injectPageThemeCSS()
    }

    private func validatedRestoreLocator(_ restoreJSON: String?, in pub: Publication) -> Locator? {
        guard let restoreJSON, !restoreJSON.isEmpty,
              let locator = try? Locator(jsonString: restoreJSON) else { return nil }
        if pub.readingOrder.firstIndexWithHREF(locator.href) != nil {
            return locator
        }
        return nil
    }

    @MainActor
    private func waitForEPUBPainted(timeoutNanoseconds: UInt64) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000.0)
        while Date() < deadline {
            if sawEPUBLocationEvent {
                return true
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return sawEPUBLocationEvent
    }

    private func inkRatio(of view: UIView) -> CGFloat {
        let bounds = view.bounds
        guard bounds.width > 8, bounds.height > 8 else { return 0 }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { _ in
            view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        guard let cg = image.cgImage else { return 0 }
        let tw = min(cg.width, 48)
        let th = min(cg.height, 64)
        var data = [UInt8](repeating: 0, count: tw * th * 4)
        guard let ctx = CGContext(
            data: &data,
            width: tw,
            height: th,
            bitsPerComponent: 8,
            bytesPerRow: tw * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        let total = tw * th
        guard total > 0 else { return 0 }
        // Uniform chat-colored page must NOT count as "ink" — measure luminance variance.
        var sum = 0.0
        var sumSq = 0.0
        for i in 0 ..< total {
            let o = i * 4
            let y = 0.2126 * Double(data[o]) + 0.7152 * Double(data[o + 1]) + 0.0722 * Double(data[o + 2])
            sum += y
            sumSq += y * y
        }
        let mean = sum / Double(total)
        let variance = max(0, sumSq / Double(total) - mean * mean)
        let std = sqrt(variance)
        // Empty themed page ≈ std < 3; real text usually >> 15.
        return CGFloat(min(1.0, std / 40.0))
    }

    /// Resolves when `locationDidChange` fires, or `false` on timeout / teardown.
    @MainActor
    private func waitForFirstEPUBLocation(timeoutNanoseconds: UInt64) async -> Bool {
        // Kept for call-site compatibility; paint wait uses waitForEPUBPainted.
        _ = timeoutNanoseconds
        return await waitForEPUBPainted(timeoutNanoseconds: 12_000_000_000)
    }

    private func resolveFirstEPUBLocationWait(success: Bool) {
        if success {
            sawEPUBLocationEvent = true
        }
        guard waitingForFirstEPUBLocation, let c = firstEPUBLocationContinuation else { return }
        waitingForFirstEPUBLocation = false
        firstEPUBLocationContinuation = nil
        c.resume(returning: success)
    }

    /// Ensure the host has a usable size before EPUBNavigator initializes spreads.
    @MainActor
    private func waitForReadableContentHostSize() async {
        for _ in 0 ..< 40 {
            view.layoutIfNeeded()
            contentHost.layoutIfNeeded()
            if contentHost.bounds.width > 32, contentHost.bounds.height > 32 {
                return
            }
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard engineKind == .epub,
              let nav = epubNavigator,
              contentHost.bounds.width > 32,
              contentHost.bounds.height > 32
        else { return }

        if nav.view.autoresizingMask.contains(.flexibleWidth) {
            nav.view.frame = contentHost.bounds
        }
        didKickEPUBLayout = true
    }

    private func teardownEngines() {
        // Before `sourceEPUBURL` and the annotation list are dropped.
        flushAnnotationsToPackage()
        sawEPUBLocationEvent = false
        resolveFirstEPUBLocationWait(success: false)
        directionalNavAdapter?.unbind()
        directionalNavAdapter = nil
        didKickEPUBLayout = false
        if let nav = epubNavigator {
            nav.willMove(toParent: nil)
            nav.view.removeFromSuperview()
            nav.removeFromParent()
        }
        epubNavigator = nil
        publication = nil
        markRestoreTask?.cancel()
        markRestoreTask = nil
        ReadiumEbookOpener.releaseCache(openedCacheURL)
        openedCacheURL = nil
        sourceEPUBURL = nil
        tocLinks = []
        epubAnnotations = []
        deletedAnnotationIDs = []
        pendingSelection = nil
        hideHighlightPicker()
        epubPositionCount = 0
        engineKind = .none
        contentsTable.reloadData()
    }

    private func makeEPUBPreferences() -> EPUBPreferences {
        let scale = Self.readiumFontScale(pt: SettingsManager.shared.ebookReaderFontSize)
        let isDark = ReaderThemeManager.shared.mode == .dark
        // Hard-coded high-contrast pair matching chat chrome:
        // dark bg #212121 + light text #ECECF1; light bg #FFFFFF + dark text #0D0D0D.
        // Never derive both from the same UIColor conversion path (easy to collapse contrast).
        let pageBG = Color(hex: isDark ? "#212121" : "#FFFFFF")!
        let pageFG = Color(hex: isDark ? "#ECECF1" : "#0D0D0D")!
        precondition(pageBG.rawValue != pageFG.rawValue)
        return EPUBPreferences(
            backgroundColor: pageBG,
            // One column — auto dual-column leaves empty gutters on iPad landscape.
            columnCount: .one,
            fontSize: scale,
            // Slightly under Readium’s 1.0 so text isn’t edge-flush, without a huge empty column.
            pageMargins: 0.85,
            // Off → readium-advanced-on so p/li/div use 1rem and follow --USER__fontSize.
            publisherStyles: false,
            scroll: false,
            spread: .never,
            textColor: pageFG,
            // Keep Readium appearance in sync, but USER colors above own the actual paint.
            theme: isDark ? .dark : .light
        )
    }

    /// Single formula for pinch preview and `submitPreferences` (pt 14…28 → Readium scale).
    private static func readiumFontScale(pt: CGFloat) -> Double {
        max(0.7, min(2.0, Double(pt / 18.0)))
    }

    private func applyEPUBPreferences() {
        epubNavigator?.submitPreferences(makeEPUBPreferences())
        applyPageSurfaceColors()
        injectPageThemeCSS()
    }

    /// Top bar / TOC chrome follow the global (system settings) theme.
    private func applyChromeColors() {
        let c = DSTheme.c
        view.backgroundColor = c.background
        topBar.backgroundColor = c.background
        topBarSeparator.backgroundColor = c.border.withAlphaComponent(0.55)
        fileTitleButton.setTitleColor(c.textPrimary, for: .normal)
        contentsButton.tintColor = c.textSecondary
        sidebarButton.tintColor = c.textSecondary
        appearanceButton.tintColor = c.textSecondary
        contentsPanelHost.backgroundColor = c.surface
        contentsTable.backgroundColor = c.surface
        contentsTitleButton.setTitleColor(c.textPrimary, for: .normal)
        contentsTitleButton.tintColor = c.textPrimary
        refreshContentsPanelChrome()
    }

    /// EPUB page + host behind the webview follow reader day/night.
    private func applyPageSurfaceColors() {
        let bg = DSTheme.reader.background
        contentHost.backgroundColor = bg
        epubNavigator?.view.backgroundColor = bg
    }

    /// Force page paint — some EPUB publisher rules ignore Readium vars alone.
    private func injectPageThemeCSS() {
        let isDark = ReaderThemeManager.shared.mode == .dark
        let bg = isDark ? "#212121" : "#FFFFFF"
        let fg = isDark ? "#ECECF1" : "#0D0D0D"
        let appearance = isDark ? "readium-night-on" : "readium-default-on"
        let script = """
        (function(){
          var r = document.documentElement;
          if (!r) return;
          r.style.setProperty('--USER__backgroundColor', '\(bg)', 'important');
          r.style.setProperty('--USER__textColor', '\(fg)', 'important');
          r.style.setProperty('--USER__appearance', '\(appearance)', 'important');
          r.style.setProperty('background-color', '\(bg)', 'important');
          r.style.setProperty('color', '\(fg)', 'important');
          if (document.body) {
            document.body.style.setProperty('background-color', '\(bg)', 'important');
            document.body.style.setProperty('color', '\(fg)', 'important');
          }
          try {
            if (window.readium && typeof window.readium.setCSSProperties === 'function') {
              window.readium.setCSSProperties({
                '--USER__backgroundColor': '\(bg)',
                '--USER__textColor': '\(fg)',
                '--USER__appearance': '\(appearance)'
              });
            }
          } catch (e) {}
        })();
        """
        Task { @MainActor [weak self] in
            _ = await self?.epubNavigator?.evaluateJavaScript(script)
        }
    }

    private func restoreLocator(json: String) {
        guard engineKind == .epub,
              let locator = try? Locator(jsonString: json) else { return }
        Task { @MainActor in
            await self.restorePageWindowAfterPinch()
            await self.epubNavigator?.go(to: locator)
        }
    }

    private func flattenTOC(_ links: [Link], depth: Int = 0) -> [Link] {
        var out: [Link] = []
        for link in links {
            out.append(link)
            out.append(contentsOf: flattenTOC(link.children, depth: depth + 1))
        }
        return out
    }

    private func refreshTitleChrome() {
        let file = documentDisplayTitle.isEmpty ? "电子书" : documentDisplayTitle
        fileTitleButton.setTitle("\(file) ▾", for: .normal)
        updateAppearanceButton()
        applyChromeColors()
        applyPageSurfaceColors()
    }

    private func scheduleProgressSave() {
        progressWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveReadingProgressNow() }
        progressWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: - Actions

    @objc private func sidebarTapped() { onToggleSidebar?() }
    @objc private func fileTitleTapped() { onFileTitleTapped?(fileTitleButton) }

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

    private func setEPUBPageTurnsEnabled(_ enabled: Bool) {
        epubNavigator?.allowsUserPageTurns = enabled
        directionalNavAdapter?.isEnabled = enabled
    }

    private func commitPinchFontSize() {
        let target = pinchTargetFontSize
        hideFontSizeHUD(animated: true)
        skipNextFontSizePreferenceApply = true
        SettingsManager.shared.ebookReaderFontSize = target
        skipNextFontSizePreferenceApply = false
        // Page DOM already has the final --USER__fontSize; sync prefs + neighbors only
        // (same pt/18 formula as the in-page script — no zoom, no second visual path).
        let scale = Self.readiumFontScale(pt: target)
        epubNavigator?.adoptPinchFontSize(scale)
        scheduleProgressSave()
    }

    private func showFontSizeHUD(_ pt: Int) {
        fontSizeHUDHideWork?.cancel()
        fontSizeHUD.text = "  \(pt)  "
        let wasHidden = fontSizeHUD.isHidden || fontSizeHUD.alpha < 0.99
        fontSizeHUD.isHidden = false
        view.bringSubviewToFront(fontSizeHUD)
        // Only animate the first reveal — animating every changed frame fights pinch FPS.
        if wasHidden {
            UIView.animate(withDuration: 0.12) {
                self.fontSizeHUD.alpha = 1
            }
        } else {
            fontSizeHUD.alpha = 1
        }
    }

    private func hideFontSizeHUD(animated: Bool) {
        fontSizeHUDHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: animated ? 0.25 : 0, animations: {
                self.fontSizeHUD.alpha = 0
            }, completion: { _ in
                self.fontSizeHUD.isHidden = true
            })
        }
        fontSizeHUDHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0.35 : 0), execute: work)
    }

    @objc private func fontSizeSettingChanged() {
        guard !skipNextFontSizePreferenceApply else { return }
        applyEPUBPreferences()
    }

    // MARK: - In-page font pinch (follow-finger CSS)

    func navigator(
        _ navigator: EPUBNavigatorViewController,
        setupUserScripts userContentController: WKUserContentController
    ) {
        // Fresh WKUserContentController per spread — add only (remove raises if absent).
        userContentController.add(fontPinchScriptProxy, name: "connectsFontPinch")
        userContentController.add(highlightScriptProxy, name: "connectsHighlight")
        let basePt = SettingsManager.shared.ebookReaderFontSize
        userContentController.addUserScript(
            WKUserScript(
                source: Self.pageWindowUserScript(),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        userContentController.addUserScript(
            WKUserScript(
                source: Self.fontPinchUserScript(basePt: basePt),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        userContentController.addUserScript(
            WKUserScript(
                source: Self.highlightCSSUserScript(),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
        )
        userContentController.addUserScript(
            WKUserScript(
                source: Self.highlightSelectionUserScript(),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        userContentController.addUserScript(
            WKUserScript(
                source: Self.highlightSelectionUserScript(),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
        )
        userContentController.addUserScript(
            WKUserScript(
                source: Self.annotationPainterUserScript(),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
        )
    }

    /// Paints highlights with the CSS Custom Highlight API.
    ///
    /// Everything here is deliberately DOM-free: wrapping `<mark>`s or absolutely
    /// positioned boxes reflowed Readium's column layout, which fired
    /// `locationDidChange` → re-decorate → reflow, and hung the web process while a
    /// native selection was still alive. Ranges are rebuilt from character offsets
    /// into the resource text, so nothing depends on Readium TextQuote.
    private static func annotationPainterUserScript() -> String {
        """
        (function(){
          if (window.__connectsAnn) return;

          var BLUE = 'connects-ann-blue';
          var GREEN = 'connects-ann-green';
          var items = {};
          var idx = null;

          var supported = !!(window.CSS && window.CSS.highlights && window.Highlight);

          function ensureStyle(){
            if (document.querySelector('style[data-connects-ann]')) return;
            var css = ''
              + '::highlight(' + BLUE + '){background-color:rgba(70,150,255,0.28);'
              + 'text-decoration:underline;text-decoration-color:rgba(40,120,235,0.95);'
              + 'text-decoration-thickness:2px;text-underline-offset:2px;}'
              + '::highlight(' + GREEN + '){background-color:rgba(60,195,110,0.28);'
              + 'text-decoration:underline;text-decoration-color:rgba(30,160,75,0.95);'
              + 'text-decoration-thickness:2px;text-underline-offset:2px;}'
              + 'mark.connects-ann{background-color:rgba(70,150,255,0.28);color:inherit;'
              + 'box-shadow:inset 0 -2px 0 rgba(40,120,235,0.95);}'
              + 'mark.connects-ann-green{background-color:rgba(60,195,110,0.28);'
              + 'box-shadow:inset 0 -2px 0 rgba(30,160,75,0.95);}';
            var s = document.createElement('style');
            s.setAttribute('data-connects-ann','1');
            s.textContent = css;
            (document.head || document.documentElement).appendChild(s);
          }

          // Tag whitelist rather than getComputedStyle: this runs once per text
          // node and a spine file here has tens of thousands of them.
          var BLOCK_TAGS = {
            p:1, div:1, li:1, h1:1, h2:1, h3:1, h4:1, h5:1, h6:1, blockquote:1,
            td:1, th:1, tr:1, table:1, ul:1, ol:1, dd:1, dt:1, dl:1, pre:1,
            section:1, article:1, aside:1, figure:1, figcaption:1, header:1,
            footer:1, main:1, nav:1, body:1
          };
          function blockElementOf(node){
            var el = node.parentElement;
            while (el && !BLOCK_TAGS[(el.nodeName || '').toLowerCase()]) {
              el = el.parentElement;
            }
            return el || document.body;
          }

          function buildIndex(){
            var root = document.body || document.documentElement;
            if (!root) return null;
            var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
              acceptNode: function(n){
                if (!n.nodeValue || !n.nodeValue.length) return NodeFilter.FILTER_REJECT;
                var p = n.parentNode;
                var tag = p ? (p.nodeName || '').toLowerCase() : '';
                if (tag === 'script' || tag === 'style' || tag === 'noscript') {
                  return NodeFilter.FILTER_REJECT;
                }
                return NodeFilter.FILTER_ACCEPT;
              }
            });
            var nodes = [], starts = [], parts = [], off = 0, n;
            // Which paragraph each run of text belongs to. Used to tidy up a
            // selection that WebKit extended past a paragraph boundary.
            var blockIds = [], blockRanges = [], curBlock = null, curId = -1;
            while ((n = walker.nextNode())) {
              var be = blockElementOf(n);
              if (be !== curBlock) {
                curBlock = be;
                curId++;
                blockRanges.push({ start: off, end: off });
              }
              blockIds.push(curId);
              nodes.push(n);
              starts.push(off);
              parts.push(n.nodeValue);
              off += n.nodeValue.length;
              blockRanges[curId].end = off;
            }
            var text = parts.join('');
            // Whitespace-collapsed mirror, so a stored quote still matches the
            // source indentation. Must stay native: a per-character loop over a
            // large spine file hangs the web process.
            return {
              nodes: nodes,
              starts: starts,
              blockIds: blockIds,
              blockRanges: blockRanges,
              text: text,
              len: off,
              norm: text.replace(/\\s+/g, ' '),
              runStarts: null,
              runRemoved: null
            };
          }

          /// Lazily table the collapsed whitespace runs: one entry per run, not per
          /// character, so mapping a normalized offset back is a binary search.
          function ensureRunTable(ix){
            if (ix.runStarts) return;
            var re = /\\s+/g, m, starts = [], removed = [], dropped = 0;
            while ((m = re.exec(ix.text))) {
              starts.push(m.index - dropped);
              dropped += m[0].length - 1;
              removed.push(dropped);
            }
            ix.runStarts = starts;
            ix.runRemoved = removed;
          }

          function rawOffset(ix, normOffset){
            ensureRunTable(ix);
            var starts = ix.runStarts;
            var lo = 0, hi = starts.length - 1, k = 0;
            while (lo <= hi) {
              var mid = (lo + hi) >> 1;
              if (starts[mid] < normOffset) { k = mid + 1; lo = mid + 1; }
              else { hi = mid - 1; }
            }
            return normOffset + (k > 0 ? ix.runRemoved[k - 1] : 0);
          }

          function index(){
            if (idx && idx.nodes.length) {
              var first = idx.nodes[0], last = idx.nodes[idx.nodes.length - 1];
              if (first.isConnected && last.isConnected) return idx;
            }
            idx = buildIndex();
            return idx;
          }

          function nodeAt(ix, offset){
            var lo = 0, hi = ix.nodes.length - 1, best = 0;
            while (lo <= hi) {
              var mid = (lo + hi) >> 1;
              if (ix.starts[mid] <= offset) { best = mid; lo = mid + 1; }
              else { hi = mid - 1; }
            }
            return best;
          }

          function makeRange(start, end){
            var ix = index();
            if (!ix || !ix.nodes.length) return null;
            if (!(end > start) || start < 0 || end > ix.len) return null;
            var i = nodeAt(ix, start), j = nodeAt(ix, Math.max(start, end - 1));
            try {
              var r = document.createRange();
              r.setStart(ix.nodes[i], Math.max(0, start - ix.starts[i]));
              r.setEnd(ix.nodes[j], Math.max(0, end - ix.starts[j]));
              return r;
            } catch (e) { return null; }
          }

          function normalize(s){
            return (s || '').replace(/\\s+/g, ' ').trim();
          }

          /// Does this stretch of text carry any actual content, as opposed to
          /// only whitespace and punctuation?
          var WORDISH = /[\\p{L}\\p{N}]/u;
          function hasWords(s){
            try { return WORDISH.test(s); } catch (e) { return /\\S/.test(s); }
          }

          /// Clean up what WebKit handed us.
          ///
          /// Dragging the handle onto a paragraph's first character makes WebKit
          /// extend the selection back over the previous paragraph's tail. Drop a
          /// leading/trailing fragment that is only punctuation/whitespace, or a
          /// tiny overshoot (a couple of characters) relative to the main span.
          function tidySelection(ix, start, end){
            if (!ix || !ix.blockIds || !ix.blockRanges) return { start: start, end: end };
            function trimEdges(s, e){
              while (s < e && /\\s/.test(ix.text.charAt(s))) s++;
              while (e > s && /\\s/.test(ix.text.charAt(e - 1))) e--;
              return { start: s, end: e };
            }
            var r = trimEdges(start, end);
            if (r.end <= r.start) return null;

            var firstBlock = ix.blockIds[nodeAt(ix, r.start)];
            var lastBlock = ix.blockIds[nodeAt(ix, r.end - 1)];
            if (firstBlock === lastBlock) return r;

            var head = ix.blockRanges[firstBlock];
            if (head) {
              var headEnd = Math.min(head.end, r.end);
              var headSlice = ix.text.slice(r.start, headEnd);
              var headLen = headEnd - r.start;
              var totalLen = r.end - r.start;
              // Punctuation-only spill, or a 1–3 char grab of the previous
              // paragraph while the real selection lives in the next one.
              if (!hasWords(headSlice) || (headLen <= 3 && totalLen > headLen * 3)) {
                r = trimEdges(headEnd, r.end);
                if (r.end <= r.start) return null;
                lastBlock = ix.blockIds[nodeAt(ix, r.end - 1)];
              }
            }
            var tail = ix.blockRanges[lastBlock];
            if (tail) {
              var tailStart = Math.max(tail.start, r.start);
              var tailSlice = ix.text.slice(tailStart, r.end);
              var tailLen = r.end - tailStart;
              var leftLen = r.end - r.start;
              if (!hasWords(tailSlice) || (tailLen <= 3 && leftLen > tailLen * 3)) {
                r = trimEdges(r.start, tailStart);
                if (r.end <= r.start) return null;
              }
            }
            return r;
          }

          function offsetOfInIndex(ix, container, offset){
            if (container && container.nodeType === 3) {
              var i = ix.nodes.indexOf(container);
              if (i >= 0) return ix.starts[i] + offset;
            }
            try {
              var probe = document.createRange();
              probe.setStart(ix.nodes[0], 0);
              probe.setEnd(container, offset);
              return probe.toString().length;
            } catch (e) { return -1; }
          }

          /// Shrink the live WebKit selection when it has spilled into the
          /// neighbouring paragraph. Called on finger-up (and coalesced during
          /// drag) so the handles are not glued to the previous paragraph's tail.
          function clampSelection(){
            var sel = window.getSelection && window.getSelection();
            if (!sel || sel.isCollapsed || sel.rangeCount < 1) return false;
            var ix = index();
            if (!ix || !ix.nodes.length) return false;
            var range = sel.getRangeAt(0);
            var s = offsetOfInIndex(ix, range.startContainer, range.startOffset);
            var e2 = offsetOfInIndex(ix, range.endContainer, range.endOffset);
            if (s < 0 || e2 < 0 || e2 <= s) return false;
            var t = tidySelection(ix, s, e2);
            if (!t || (t.start === s && t.end === e2)) return false;
            var nr = makeRange(t.start, t.end);
            if (!nr) return false;
            try {
              sel.removeAllRanges();
              sel.addRange(nr);
              window.__connectsSavedRange = nr.cloneRange();
              window.__connectsSavedText = normalize(ix.text.slice(t.start, t.end));
              return true;
            } catch (err) { return false; }
          }

          /// Prefer the offsets we just captured. A mismatched quote used to discard
          /// them and fall through to a search that often failed for new highlights,
          /// so the underline never appeared even though the sidebar had the row.
          function resolveOffsets(item){
            var ix = index();
            if (!ix) return null;
            var quote = normalize(item.quote);
            if (typeof item.start === 'number' && typeof item.end === 'number'
                && item.end > item.start && item.start >= 0 && item.end <= ix.len) {
              var got = normalize(ix.text.slice(item.start, item.end));
              if (!quote || got === quote || got.length > 0) {
                return { start: item.start, end: item.end };
              }
            }
            if (!quote) return null;
            var at = ix.text.indexOf(quote);
            if (at >= 0) return { start: at, end: at + quote.length };
            at = ix.norm.indexOf(quote);
            if (at < 0) return null;
            return { start: rawOffset(ix, at), end: rawOffset(ix, at + quote.length) };
          }

          function paint(){
            ensureStyle();
            var blue = [], green = [];
            for (var id in items) {
              var it = items[id];
              if (!it.range) continue;
              (it.color === 'green' ? green : blue).push(it.range);
            }
            if (supported) {
              try {
                var make = function(ranges){
                  return new (Function.prototype.bind.apply(Highlight, [null].concat(ranges)))();
                };
                if (blue.length) CSS.highlights.set(BLUE, make(blue));
                else CSS.highlights['delete'](BLUE);
                if (green.length) CSS.highlights.set(GREEN, make(green));
                else CSS.highlights['delete'](GREEN);
                return true;
              } catch (e) { supported = false; }
            }
            return paintFallbackMarks();
          }

          /// Only for engines without the Custom Highlight API.
          function paintFallbackMarks(){
            var painted = 0;
            for (var id in items) {
              var it = items[id];
              if (!it.range) continue;
              if (document.querySelector('mark.connects-ann[data-connects-id="' + id + '"]')) {
                painted++;
                continue;
              }
              try {
                var m = document.createElement('mark');
                m.className = 'connects-ann' + (it.color === 'green' ? ' connects-ann-green' : '');
                m.setAttribute('data-connects-id', id);
                it.range.surroundContents(m);
                painted++;
              } catch (e) {}
            }
            idx = null;
            return painted > 0;
          }

          function attach(item){
            var res = resolveOffsets(item);
            if (!res) { item.range = null; return false; }
            item.start = res.start;
            item.end = res.end;
            item.range = makeRange(res.start, res.end);
            return !!item.range;
          }

          function isFootnoteish(el){
            try {
              var cur = el && el.nodeType === 3 ? el.parentElement : el;
              while (cur && cur.nodeType === 1) {
                var tag = (cur.tagName || '').toLowerCase();
                if (tag === 'a' || tag === 'sup') return true;
                cur = cur.parentElement;
              }
            } catch (e) {}
            return false;
          }

          function post(payload){
            try {
              if (window.webkit && window.webkit.messageHandlers
                && window.webkit.messageHandlers.connectsHighlight) {
                window.webkit.messageHandlers.connectsHighlight.postMessage(payload);
              }
            } catch (e) {}
          }

          function hitTest(x, y){
            var caret = null;
            try {
              if (document.caretRangeFromPoint) caret = document.caretRangeFromPoint(x, y);
            } catch (e) {}
            if (!caret) return null;
            for (var id in items) {
              var it = items[id];
              if (!it.range) continue;
              try {
                if (it.range.isPointInRange(caret.startContainer, caret.startOffset)) return id;
              } catch (e) {}
            }
            return null;
          }

          function onTap(e){
            try {
              if (window.__connectsBarVisible || window.__connectsHLLock) return;
              var sel = window.getSelection && window.getSelection();
              if (sel && !sel.isCollapsed) return;
              if (isFootnoteish(e.target)) {
                // Let Readium resolve the note, but tell native to put the card up
                // now so the marker responds to the tap immediately.
                post({ action: 'footnotePending' });
                return;
              }
              var pt = e.changedTouches && e.changedTouches.length
                ? e.changedTouches[0]
                : e;
              var id = hitTest(pt.clientX, pt.clientY);
              if (!id) return;
              var now = Date.now();
              if (window.__connectsLastNoteOpenAt && (now - window.__connectsLastNoteOpenAt) < 450) return;
              window.__connectsLastNoteOpenAt = now;
              e.preventDefault();
              e.stopPropagation();
              if (e.stopImmediatePropagation) e.stopImmediatePropagation();
              post({ action: 'openNote', id: id });
            } catch (err) {}
          }
          // A page swipe often lifts off on top of a highlight. Without this the
          // touchend below fired and the note sheet opened mid-scroll.
          var tapX = 0, tapY = 0, tapAt = 0, tapMoved = false;
          document.addEventListener('touchstart', function(e){
            var t = e.touches && e.touches[0];
            if (!t) return;
            tapX = t.clientX; tapY = t.clientY; tapAt = Date.now(); tapMoved = false;
          }, { passive: true, capture: true });
          document.addEventListener('touchmove', function(e){
            var t = e.touches && e.touches[0];
            if (!t) return;
            if (Math.abs(t.clientX - tapX) > 8 || Math.abs(t.clientY - tapY) > 8) tapMoved = true;
          }, { passive: true, capture: true });

          function onTouchEndTap(e){
            if (tapMoved) return;
            if (Date.now() - tapAt > 600) return;
            var t = e.changedTouches && e.changedTouches[0];
            if (t && (Math.abs(t.clientX - tapX) > 8 || Math.abs(t.clientY - tapY) > 8)) return;
            onTap(e);
          }
          document.addEventListener('click', onTap, true);
          document.addEventListener('touchend', onTouchEndTap, true);

          window.__connectsAnn = {
            supported: function(){ return supported; },
            invalidate: function(){ idx = null; },
            setAll: function(list){
              items = {};
              for (var i = 0; i < (list || []).length; i++) {
                var raw = list[i];
                if (!raw || !raw.id) continue;
                var it = {
                  id: raw.id,
                  start: raw.start,
                  end: raw.end,
                  quote: raw.quote,
                  color: raw.color,
                  range: null
                };
                attach(it);
                items[it.id] = it;
              }
              paint();
              var n = 0;
              for (var k in items) { if (items[k].range) n++; }
              return n;
            },
            add: function(raw){
              if (!raw || !raw.id) return false;
              // Fresh index — a prior page-window restore can leave offsets pointing
              // at detached nodes, which made brand-new highlights attach as null.
              idx = null;
              var it = {
                id: raw.id,
                start: raw.start,
                end: raw.end,
                quote: raw.quote,
                color: raw.color,
                range: null
              };
              var ok = attach(it);
              items[it.id] = it;
              paint();
              return ok;
            },
            remove: function(id){
              if (!items[id]) return false;
              delete items[id];
              try {
                var m = document.querySelector('mark.connects-ann[data-connects-id="' + id + '"]');
                if (m && m.parentNode) {
                  while (m.firstChild) m.parentNode.insertBefore(m.firstChild, m);
                  m.parentNode.removeChild(m);
                  idx = null;
                }
              } catch (e) {}
              paint();
              return true;
            },
            has: function(id){ return !!(items[id] && items[id].range); },
            clampSelection: clampSelection,
            /// Offsets for the range stashed when the color bar came up.
            capture: function(){
              var ix = index();
              if (!ix || !ix.nodes.length) return null;
              // Tidy the live selection first so stash + offsets agree.
              try { clampSelection(); } catch (e) {}
              var range = window.__connectsSavedRange;
              if (!range) {
                var sel = window.getSelection && window.getSelection();
                if (sel && !sel.isCollapsed && sel.rangeCount > 0) range = sel.getRangeAt(0);
              }
              if (!range) return null;
              var s = offsetOfInIndex(ix, range.startContainer, range.startOffset);
              var e2 = offsetOfInIndex(ix, range.endContainer, range.endOffset);
              if (s < 0 || e2 < 0 || e2 <= s) return null;
              var t = tidySelection(ix, s, e2);
              if (!t) return null;
              return { start: t.start, end: t.end, quote: normalize(ix.text.slice(t.start, t.end)) };
            },
            /// Where the highlight sits inside this resource, as a Readium
            /// progression. Reporting it lets the navigator do the actual moving:
            /// scrolling a column-paginated document from JS fought Readium's snap
            /// and locked the reader up.
            measure: function(id){
              var it = items[id];
              if (!it) return { error: 'not in painter set' };
              var vw = window.innerWidth || document.documentElement.clientWidth || 1;
              var vh = window.innerHeight || document.documentElement.clientHeight || 1;
              var se = document.scrollingElement || document.documentElement;
              var scrollMode = false;
              try {
                scrollMode = getComputedStyle(document.documentElement)
                  .getPropertyValue('--USER__view').trim() === 'readium-scroll-on';
              } catch (e) {}

              // First non-empty line box, not the bounding box: a highlight that
              // straddles a column break has a bounding box spanning both pages,
              // which is never "visible" and points at the wrong page.
              var r = null;
              if (it.range) {
                try {
                  var rects = it.range.getClientRects();
                  for (var i = 0; i < (rects ? rects.length : 0); i++) {
                    if (rects[i].width || rects[i].height) { r = rects[i]; break; }
                  }
                  if (!r) {
                    var b = it.range.getBoundingClientRect();
                    if (b && (b.width || b.height)) r = b;
                  }
                } catch (e) {}
              }

              if (r) {
                // Work in whole pages. Reporting the highlight's exact offset let
                // Readium's snapping round to the neighbouring page when the text sat
                // near a column boundary; the jump then measured the same value again,
                // decided nothing had changed and gave up without moving. Aiming at
                // the middle of the target page always snaps back to that same page.
                var pageSize = scrollMode ? vh : vw;
                var total = Math.max(1, scrollMode ? (se.scrollHeight || 1) : (se.scrollWidth || 1));
                var current = scrollMode
                  ? (window.scrollY || se.scrollTop || 0)
                  : (window.scrollX || se.scrollLeft || 0);
                var pos = (scrollMode ? r.top : r.left) + current;
                var page = Math.floor(pos / Math.max(1, pageSize));
                var prog = (page * pageSize + pageSize / 2) / total;
                if (isFinite(prog)) {
                  return {
                    progression: Math.max(0, Math.min(1, prog)),
                    visible: page === Math.round(current / Math.max(1, pageSize)),
                    approx: false,
                    page: page,
                    currentPage: Math.round(current / Math.max(1, pageSize)),
                    pages: Math.round(total / Math.max(1, pageSize))
                  };
                }
              }

              // No usable geometry. WebKit hands back empty rects for ranges sitting
              // far outside the viewport in a column-paginated document, which made
              // jumps from later pages report nothing at all and do nothing. The
              // character offset is a good enough first guess; once the move lands
              // near it, real rects come back and the caller refines from there.
              var ix = index();
              if (ix && ix.len && typeof it.start === 'number') {
                return {
                  progression: Math.max(0, Math.min(1, it.start / ix.len)),
                  visible: false,
                  approx: true
                };
              }
              return { error: it.range ? 'no geometry, no offsets' : 'quote not found in this resource' };
            },
            /// Land on the highlight's own page without going through a
            /// progression. Round-tripping one through Readium means the value is
            /// rebuilt from `scrollWidth` and then re-snapped against Readium's
            /// cached `viewportWidth`, and either step can round to a neighbouring
            /// page. Here the page index comes straight from the range's rect and
            /// the offset is an exact multiple of it, which is the same grid
            /// Readium's own `snapOffset` produces when nothing is stale.
            scrollToPage: function(id){
              var it = items[id];
              if (!it || !it.range) return { error: 'nothing painted for this id' };
              var vw = window.innerWidth || document.documentElement.clientWidth || 1;
              var vh = window.innerHeight || document.documentElement.clientHeight || 1;
              var se = document.scrollingElement || document.documentElement;
              var scrollMode = false;
              try {
                scrollMode = getComputedStyle(document.documentElement)
                  .getPropertyValue('--USER__view').trim() === 'readium-scroll-on';
              } catch (e) {}
              var r = null;
              try {
                var rects = it.range.getClientRects();
                for (var i = 0; i < (rects ? rects.length : 0); i++) {
                  if (rects[i].width || rects[i].height) { r = rects[i]; break; }
                }
                if (!r) {
                  var b = it.range.getBoundingClientRect();
                  if (b && (b.width || b.height)) r = b;
                }
              } catch (e) {}
              if (!r) return { error: 'no geometry to scroll to' };
              var pageSize = scrollMode ? vh : vw;
              var current = scrollMode
                ? (window.scrollY || se.scrollTop || 0)
                : (window.scrollX || se.scrollLeft || 0);
              var pos = (scrollMode ? r.top : r.left) + current;
              var page = Math.floor(pos / Math.max(1, pageSize));
              var offset = page * pageSize;
              try {
                if (scrollMode) se.scrollTo({ top: offset, behavior: 'instant' });
                else se.scrollTo({ left: offset, behavior: 'instant' });
              } catch (e) {
                if (scrollMode) se.scrollTop = offset; else se.scrollLeft = offset;
              }
              var now = scrollMode
                ? (window.scrollY || se.scrollTop || 0)
                : (window.scrollX || se.scrollLeft || 0);
              return { page: page, wanted: offset, landed: now, pageSize: pageSize };
            }
          };
        })();
        """
    }

    /// Persistent mark styles so wrapped selection stays visible even if decorations lag.
    private static func highlightCSSUserScript() -> String {
        """
        (function(){
          if (window.__connectsHLCss) return;
          window.__connectsHLCss = true;
          var css = ''
            + 'mark.connects-hl{-webkit-box-decoration-break:clone;box-decoration-break:clone;cursor:pointer;'
            + 'pointer-events:auto;border-radius:2px;padding:0 1px;color:inherit!important;}'
            + 'mark.connects-hl-blue{background-color:rgba(70,150,255,0.40)!important;'
            + 'box-shadow:inset 0 -2.5px 0 rgba(70,150,255,0.85);}'
            + 'mark.connects-hl-green{background-color:rgba(50,190,100,0.40)!important;'
            + 'box-shadow:inset 0 -2.5px 0 rgba(50,190,100,0.85);}'
            + 'div.connects-hl-box{pointer-events:auto;position:absolute;z-index:20;border-radius:2px;cursor:pointer;}'
            + 'div.connects-hl-box-blue{background-color:rgba(70,150,255,0.40)!important;}'
            + 'div.connects-hl-box-green{background-color:rgba(50,190,100,0.40)!important;}';
          var s = document.createElement('style');
          s.setAttribute('data-connects-hl','1');
          s.textContent = css;
          (document.head || document.documentElement).appendChild(s);
        })();
        """
    }

    /// Direct page hook — does not depend on Readium menu / currentLocation.
    /// Emit only after the finger lifts so mid-drag selectionchange noise is ignored.
    /// When the color bar is up (or a page scroll fires), clear selection and tell native to drop chrome.
    private static func highlightSelectionUserScript() -> String {
        """
        (function(){
          if (window.__connectsHighlightHook) return;
          window.__connectsHighlightHook = true;
          var lastText = '';
          var lastAt = 0;
          var ignoreScrollUntil = 0;
          var touchSX = null, touchSY = null;
          var noteGestureMoved = false;
          function post(payload) {
            try {
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.connectsHighlight) {
                window.webkit.messageHandlers.connectsHighlight.postMessage(payload);
              }
            } catch (e) {}
          }
          function hasActiveSelection() {
            try {
              if (window.__connectsSavedRange) return true;
              var sel = window.getSelection && window.getSelection();
              return !!(sel && !sel.isCollapsed && sel.rangeCount > 0);
            } catch (e) { return false; }
          }
          function dismissSelection() {
            if (window.__connectsHLLock) return;
            if (!hasActiveSelection() && !lastText && !window.__connectsBarVisible) return;
            try {
              var sel = window.getSelection && window.getSelection();
              if (sel) sel.removeAllRanges();
            } catch (e) {}
            try { window.__connectsSavedRange = null; } catch (e) {}
            try { window.__connectsSavedText = null; } catch (e) {}
            try { window.__connectsBarVisible = false; } catch (e) {}
            lastText = '';
            post({ action: 'dismiss' });
          }
          function emit() {
            try {
              // Peel a spilled previous-paragraph tail before the color bar reads
              // the selection, so the handles and the saved range agree.
              try {
                if (window.__connectsAnn && window.__connectsAnn.clampSelection) {
                  window.__connectsAnn.clampSelection();
                }
              } catch (ce) {}
              var sel = window.getSelection && window.getSelection();
              if (!sel || sel.isCollapsed || sel.rangeCount < 1) return;
              var t = (sel.toString() || '').replace(/\\s+/g, ' ').trim();
              if (!t || t.length < 1) return;
              var now = Date.now();
              if (t === lastText && (now - lastAt) < 900) return;
              lastText = t;
              lastAt = now;
              ignoreScrollUntil = now + 450;
              var range = sel.getRangeAt(0);
              try {
                window.__connectsSavedRange = range.cloneRange();
                window.__connectsSavedText = t;
              } catch (e) {}
              var r = range.getBoundingClientRect();
              var rects = [];
              try {
                var list = range.getClientRects();
                for (var i = 0; i < list.length; i++) {
                  var rr = list[i];
                  if (rr.width < 1 || rr.height < 1) continue;
                  rects.push({ x: rr.left, y: rr.top, w: rr.width, h: rr.height });
                }
              } catch (e2) {}
              var sx = window.scrollX || document.documentElement.scrollLeft || 0;
              var sy = window.scrollY || document.documentElement.scrollTop || 0;
              post({ text: t, x: r.left, y: r.top, w: r.width, h: r.height, rects: rects, sx: sx, sy: sy });
            } catch (e) {}
          }
          document.addEventListener('touchend', function(){ setTimeout(emit, 60); }, true);
          document.addEventListener('mouseup', function(){ setTimeout(emit, 60); }, true);
          document.addEventListener('selectionchange', function(){
            try {
              var sel = window.getSelection && window.getSelection();
              if (!sel || sel.isCollapsed || sel.rangeCount < 1) {
                lastText = '';
                // Do NOT clear __connectsSavedRange / dismiss the color bar here.
                // Returning false from the native menu often collapses selection while
                // the bar is up — wiping the stash made every highlight paint fail.
                return;
              }
              // Coalesce: peel a punctuation spill without fighting every micro-move.
              if (!window.__connectsClampScheduled) {
                window.__connectsClampScheduled = true;
                setTimeout(function(){
                  window.__connectsClampScheduled = false;
                  try {
                    if (window.__connectsAnn && window.__connectsAnn.clampSelection) {
                      window.__connectsAnn.clampSelection();
                    }
                  } catch (ce) {}
                }, 40);
              }
              // Keep stash fresh every time selection exists (menu-suppress clears
              // the live selection before native async stash can run).
              window.__connectsSavedRange = sel.getRangeAt(0).cloneRange();
              window.__connectsSavedText = (sel.toString() || '').replace(/\\s+/g, ' ').trim();
            } catch (e) {}
          }, true);
          document.addEventListener('scroll', function(){
            if (window.__connectsHLLock) return;
            if (Date.now() < ignoreScrollUntil) return;
            dismissSelection();
          }, true);
          window.addEventListener('scroll', function(){
            if (window.__connectsHLLock) return;
            if (Date.now() < ignoreScrollUntil) return;
            dismissSelection();
          }, true);
          document.addEventListener('touchstart', function(e){
            if (e.touches && e.touches.length === 1) {
              touchSX = e.touches[0].clientX;
              touchSY = e.touches[0].clientY;
              noteGestureMoved = false;
            }
          }, true);
          document.addEventListener('touchmove', function(e){
            if (e.touches && e.touches.length === 1 && touchSX != null) {
              var mdx = Math.abs(e.touches[0].clientX - touchSX);
              var mdy = Math.abs(e.touches[0].clientY - touchSY);
              if (mdx > 10 || mdy > 10) noteGestureMoved = true;
            }
            if (window.__connectsHLLock) return;
            // Only after the color bar is up — avoid killing handle-drag while selecting.
            if (!window.__connectsBarVisible) return;
            if (!e.touches || e.touches.length !== 1 || touchSX == null) return;
            var dx = Math.abs(e.touches[0].clientX - touchSX);
            var dy = Math.abs(e.touches[0].clientY - touchSY);
            if (dx > 24 || dy > 30) dismissSelection();
          }, { passive: true, capture: true });
          // Tap highlight mark / per-line box → open note (click + careful touchend).
          // Never steal footnote / index markers like [1] (noteref / <sup>).
          // Never treat a page swipe that ends on a mark as a note tap.
          function isFootnoteTarget(el){
            try {
              var cur = el && el.nodeType === 3 ? el.parentElement : el;
              while (cur && cur.nodeType === 1) {
                var tag = (cur.tagName || '').toLowerCase();
                var role = (cur.getAttribute('role') || '').toLowerCase();
                var epubType = (cur.getAttribute('epub:type') || cur.getAttribute('type') || '').toLowerCase();
                var cls = (typeof cur.className === 'string' ? cur.className : (cur.getAttribute('class') || '')).toLowerCase();
                if (tag === 'a') {
                  if (cls.indexOf('noteref') >= 0 || epubType.indexOf('noteref') >= 0 || role === 'doc-noteref') return true;
                  var href = (cur.getAttribute('href') || '').toLowerCase();
                  if (href.indexOf('footnote') >= 0 || href.indexOf('noteref') >= 0 || /#(fn|n|note)\\d*/.test(href)) return true;
                  var at = (cur.textContent || '').replace(/\\s+/g, '').trim();
                  if (/^\\[\\d+\\]$/.test(at)) return true;
                }
                if (tag === 'sup') {
                  var st = (cur.textContent || '').replace(/\\s+/g, '').trim();
                  if (/^\\[\\d+\\]$/.test(st) || /^\\d+$/.test(st)) return true;
                }
                if (epubType.indexOf('footnote') >= 0 || epubType.indexOf('noteref') >= 0 || role === 'doc-footnote') return true;
                cur = cur.parentElement;
              }
            } catch (e) {}
            return false;
          }
          function openNoteFromEvent(e){
            try {
              var el = e.target;
              if (!el || !el.closest) return false;
              if (isFootnoteTarget(el)) return false;
              var m = el.closest('mark.connects-hl, div.connects-hl-box');
              if (!m) return false;
              var id = m.getAttribute('data-connects-id');
              if (!id) return false;
              var now = Date.now();
              if (window.__connectsLastNoteOpenAt && (now - window.__connectsLastNoteOpenAt) < 450) return false;
              window.__connectsLastNoteOpenAt = now;
              e.preventDefault();
              e.stopPropagation();
              if (e.stopImmediatePropagation) e.stopImmediatePropagation();
              post({ action: 'openNote', id: id });
              return true;
            } catch (err) { return false; }
          }
          window.__connectsScrollToAnn = function(id){
            try {
              if (!id) return false;
              var el = document.querySelector('mark.connects-hl[data-connects-id="'+id+'"]')
                || document.querySelector('div.connects-hl-box[data-connects-id="'+id+'"]');
              if (!el) {
                var boxes = document.querySelectorAll('[id^="r2-decoration-"]');
                for (var i = 0; i < boxes.length; i++) {
                  var bid = boxes[i].id || '';
                  if (bid.indexOf(id) >= 0) { el = boxes[i]; break; }
                }
              }
              if (!el) return false;
              var r = el.getBoundingClientRect();
              var se = document.scrollingElement || document.documentElement;
              var vw = window.innerWidth || se.clientWidth || 0;
              var vh = window.innerHeight || se.clientHeight || 0;
              if (r.left < 0 || r.right > vw || r.top < 0 || r.bottom > vh) {
                var dx = 0, dy = 0;
                if (r.left < 0) dx = r.left - 24;
                else if (r.right > vw) dx = r.right - vw + 24;
                if (r.top < 0) dy = r.top - 24;
                else if (r.bottom > vh) dy = r.bottom - vh + 24;
                if (Math.abs(dx) > 1 || Math.abs(dy) > 1) {
                  try { window.scrollBy(dx, dy); } catch (e) {}
                  try { if (se && se.scrollLeft != null) se.scrollLeft += dx; } catch (e2) {}
                  try { if (se && se.scrollTop != null) se.scrollTop += dy; } catch (e3) {}
                }
              }
              return true;
            } catch (e) { return false; }
          };
          document.addEventListener('click', function(e){ openNoteFromEvent(e); }, true);
          document.addEventListener('touchend', function(e){
            if (noteGestureMoved) return;
            if (!e.changedTouches || e.changedTouches.length !== 1) return;
            var t = e.changedTouches[0];
            if (touchSX != null && touchSY != null) {
              if (Math.abs(t.clientX - touchSX) > 10 || Math.abs(t.clientY - touchSY) > 10) return;
            }
            openNoteFromEvent(e);
          }, true);
        })();
        """
    }

    fileprivate func handleConnectsHighlightMessage(_ body: Any) {
        guard engineKind == .epub else { return }
        guard let dict = body as? [String: Any] else { return }
        if (dict["action"] as? String) == "dismiss" {
            if !isCommittingHighlight {
                dismissSelectionChrome(clearNativeSelection: true)
            }
            return
        }
        if (dict["action"] as? String) == "openNote",
           let id = dict["id"] as? String {
            presentNoteEditor(forAnnotationID: id)
            return
        }
        if (dict["action"] as? String) == "footnotePending" {
            presentFootnotePlaceholder()
            return
        }
        guard let text = dict["text"] as? String
        else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1 else { return }
        if ConnectsNoteSheet.isVisible { return }

        if let live = epubNavigator?.currentSelection {
            pendingSelection = live
            pendingLocatorJSON = try? live.locator.jsonString()
            pendingQuote = live.locator.text.highlight ?? trimmed
            pendingAnchorFrame = live.frame
        } else if pendingSelection == nil {
            // Only use the weak location+quote fallback when we do not already
            // hold a full Readium selection (do not wipe before/after context).
            if let loc = epubNavigator?.currentLocation {
                pendingLocatorJSON = try? Self.locatorFromQuoteFallback(base: loc, quote: trimmed).jsonString()
            }
            pendingQuote = trimmed
        } else {
            pendingQuote = pendingQuote ?? trimmed
        }

        if let rects = dict["rects"] as? [[String: Any]] {
            let parsed: [CGRect] = rects.compactMap { r in
                guard let x = r["x"] as? Double,
                      let y = r["y"] as? Double,
                      let w = r["w"] as? Double,
                      let h = r["h"] as? Double,
                      w > 1, h > 1
                else { return nil }
                return CGRect(x: x, y: y, width: w, height: h)
            }
            if !parsed.isEmpty {
                pendingSelectionRects = parsed
            }
        }
        if let sx = dict["sx"] as? Double, let sy = dict["sy"] as? Double {
            pendingSelectionScroll = CGPoint(x: sx, y: sy)
        }

        if let x = dict["x"] as? Double,
           let y = dict["y"] as? Double,
           let w = dict["w"] as? Double,
           let h = dict["h"] as? Double,
           w > 1, h > 1,
           let web = findEPUBWebView() {
            let jsRect = CGRect(x: x, y: y, width: w, height: h)
            let inNav = web.convert(jsRect, to: epubNavigator?.view)
            if inNav.width > 1, inNav.height > 1 {
                pendingAnchorFrame = inNav
            }
        }

        if highlightPickerOverlay == nil {
            Task { @MainActor in
                await self.stashSelectionRange()
                guard self.highlightPickerOverlay == nil, !ConnectsNoteSheet.isVisible else { return }
                self.presentHighlightPicker(quote: trimmed, anchorInNavigator: self.pendingAnchorFrame)
            }
        }
    }

    /// Readium TestApp stores `selection.locator` as-is for decorations.
    /// Only the weak quote fallback (no real Selection) strips page-progress cssSelector.
    private static func locatorFromQuoteFallback(base: Locator, quote: String) -> Locator {
        base.copy(
            locations: { $0.cssSelector = nil },
            text: { $0 = Locator.Text(highlight: quote) }
        )
    }

    private func findEPUBWebView() -> UIView? {
        guard let root = epubNavigator?.view else { return nil }
        var found: UIView?
        func walk(_ v: UIView) {
            if found != nil { return }
            if v is WKWebView { found = v; return }
            v.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    fileprivate func handleInPageFontPinchMessage(_ body: Any) {
        guard engineKind == .epub,
              let dict = body as? [String: Any],
              let phase = dict["phase"] as? String
        else { return }
        let pt = (dict["pt"] as? Double).map { CGFloat($0) }
            ?? (dict["pt"] as? Int).map { CGFloat($0) }
            ?? pinchTargetFontSize
        switch phase {
        case "began":
            isFontPinching = true
            setEPUBPageTurnsEnabled(false)
            pinchStartFontSize = SettingsManager.snapEbookFontSize(pt)
            pinchTargetFontSize = pinchStartFontSize
            showFontSizeHUD(Int(pinchTargetFontSize.rounded()))
            // Do NOT evaluateJavaScript prepare here — the in-page script already
            // truncates the DOM synchronously on touchstart. A second async round-trip
            // mid-gesture fights follow-finger reflow.
        case "changed":
            guard isFontPinching else { return }
            pinchTargetFontSize = SettingsManager.snapEbookFontSize(pt)
            showFontSizeHUD(Int(pinchTargetFontSize.rounded()))
        case "ended", "cancelled":
            guard isFontPinching else { return }
            isFontPinching = false
            pinchTargetFontSize = SettingsManager.snapEbookFontSize(pt)
            // JS already restored the page window on touchend — commit prefs only.
            // Repaint once after reflow settles: the DOM window was rebuilt, so the
            // painter's text index is stale.
            commitPinchFontSize()
            setEPUBPageTurnsEnabled(true)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                _ = await self.epubNavigator?.evaluateJavaScript(
                    "try { window.__connectsAnn && window.__connectsAnn.invalidate(); } catch (e) {}"
                )
                await self.syncAnnotationsToPage()
            }
        default:
            break
        }
    }

    /// Pinch-only ±10-page DOM window. Normal reading keeps the full chapter so
    /// Readium TOC / cross-chapter `.end` landing is never fought by retarget.
    private static func pageWindowUserScript() -> String {
        """
        (function(){
          if (window.__connectsPageWindowInstalled) return;
          window.__connectsPageWindowInstalled = true;

          var RADIUS = 10;
          var windowCenter = 0;
          var fullBlocks = null;
          var root = null;
          var busy = false;
          var isTruncated = false;

          function pageWidth(){
            return Math.max(1, window.innerWidth || document.documentElement.clientWidth || 1);
          }
          function pageHeight(){
            return Math.max(1, window.innerHeight || document.documentElement.clientHeight || 1);
          }
          function isScrollMode(){
            try {
              return getComputedStyle(document.documentElement)
                .getPropertyValue('--USER__view').trim() === 'readium-scroll-on';
            } catch (e) { return false; }
          }
          function scrollLeft(){
            return window.scrollX || document.documentElement.scrollLeft || document.body.scrollLeft || 0;
          }
          function scrollTop(){
            return window.scrollY || document.documentElement.scrollTop || document.body.scrollTop || 0;
          }
          function totalPages(){
            if (isScrollMode()) {
              var sh = Math.max(
                document.documentElement.scrollHeight || 0,
                document.body ? document.body.scrollHeight : 0
              );
              return Math.max(1, Math.round(sh / pageHeight()));
            }
            var sw = Math.max(
              document.documentElement.scrollWidth || 0,
              document.body ? document.body.scrollWidth : 0
            );
            return Math.max(1, Math.round(sw / pageWidth()));
          }
          function currentPage(){
            if (isScrollMode()) {
              return Math.max(0, Math.round(scrollTop() / pageHeight()));
            }
            return Math.max(0, Math.round(scrollLeft() / pageWidth()));
          }
          function blockChildren(el){
            return Array.prototype.slice.call(el.children).filter(function(n){
              var t = (n.tagName || '').toLowerCase();
              return t && t !== 'script' && t !== 'style' && t !== 'link' && t !== 'meta';
            });
          }
          function ensureCatalog(){
            if (fullBlocks) return;
            root = document.body;
            if (!root) return;
            fullBlocks = blockChildren(root);
            window.__connectsPageStash = { all: fullBlocks.slice() };
          }
          function absolutePage(){
            if (!isTruncated) return currentPage();
            var lo = Math.max(0, windowCenter - RADIUS);
            return lo + currentPage();
          }
          function goLocalPage(localPage){
            localPage = Math.max(0, localPage|0);
            if (isScrollMode()) {
              window.scrollTo(0, localPage * pageHeight());
              return;
            }
            var pw = pageWidth();
            var newTotal = totalPages();
            var prog = newTotal <= 1 ? 0 : (localPage / (newTotal - 1));
            try {
              if (window.readium && typeof window.readium.scrollToPosition === 'function') {
                window.readium.scrollToPosition(String(prog), 'ltr', false);
                return;
              }
            } catch (e) {}
            document.documentElement.scrollLeft = localPage * pw;
            if (document.body) document.body.scrollLeft = localPage * pw;
          }
          function pageSpanForElement(el){
            var r = el.getBoundingClientRect();
            if (isScrollMode()) {
              var top = r.top + scrollTop();
              var bottom = top + Math.max(r.height, 1);
              var ph = pageHeight();
              return {
                p0: Math.floor(top / ph),
                p1: Math.floor((bottom - 1) / ph)
              };
            }
            var left = r.left + scrollLeft();
            var right = left + Math.max(r.width, 1);
            var pw = pageWidth();
            return {
              p0: Math.floor(left / pw),
              p1: Math.floor((right - 1) / pw)
            };
          }
          /// Restore full DOM and remap scroll from local → absolute page.
          function restoreAllKeepingScroll(){
            if (!fullBlocks || !root) {
              isTruncated = false;
              return;
            }
            var abs = absolutePage();
            fullBlocks.forEach(function(n){ root.appendChild(n); });
            try {
              if (window.__connectsPageStash) {
                window.__connectsPageStash.beforeFrag = null;
                window.__connectsPageStash.afterFrag = null;
              }
            } catch (e) {}
            isTruncated = false;
            windowCenter = abs;
            void root.offsetWidth;
            goLocalPage(abs);
          }
          function truncateToWindow(center){
            if (busy) return;
            busy = true;
            try {
              ensureCatalog();
              if (!fullBlocks || !root || fullBlocks.length < 3) {
                isTruncated = false;
                return;
              }
              if (isTruncated) {
                restoreAllKeepingScroll();
              }
              void root.offsetWidth;
              var pages = totalPages();
              center = Math.max(0, Math.min(pages - 1, center|0));
              var lo = Math.max(0, center - RADIUS);
              var hi = Math.min(pages - 1, center + RADIUS);
              var before = [];
              var after = [];
              fullBlocks.forEach(function(n){
                var span = pageSpanForElement(n);
                if (span.p1 < lo) before.push(n);
                else if (span.p0 > hi) after.push(n);
              });
              if (before.length + after.length < 2) {
                windowCenter = center;
                isTruncated = false;
                return;
              }
              var fragB = document.createDocumentFragment();
              var fragA = document.createDocumentFragment();
              before.forEach(function(n){ fragB.appendChild(n); });
              after.forEach(function(n){ fragA.appendChild(n); });
              window.__connectsPageStash.beforeFrag = fragB;
              window.__connectsPageStash.afterFrag = fragA;
              windowCenter = center;
              isTruncated = true;
              var localPage = Math.max(0, center - lo);
              goLocalPage(localPage);
            } finally {
              busy = false;
            }
          }
          function prepareForPinch(){
            if (busy) return;
            truncateToWindow(absolutePage());
          }
          function restoreAfterPinch(){
            if (busy) return;
            if (!isTruncated) return;
            busy = true;
            try {
              restoreAllKeepingScroll();
            } finally {
              busy = false;
            }
          }

          window.__connectsPageWindow = {
            prepareForPinch: prepareForPinch,
            restoreAfterPinch: restoreAfterPinch,
            truncateToWindow: truncateToWindow,
            restoreAll: restoreAfterPinch,
            isTruncated: function(){ return isTruncated; }
          };
        })();
        """
    }

    /// Preview == final: same `--USER__fontSize` path as commit (no CSS zoom).
    /// Damped mapping: needs a larger finger travel to span min…max; snaps to even pt.
    /// Temporarily truncates the chapter DOM for lighter reflow during the pinch only.
    private static func fontPinchUserScript(basePt: CGFloat) -> String {
        let base = String(format: "%.2f", Double(SettingsManager.snapEbookFontSize(basePt)))
        return """
        (function(){
          if (window.__connectsFontPinchInstalled) return;
          window.__connectsFontPinchInstalled = true;
          var minPt = 14, maxPt = 28, step = 2, basePt = \(base);
          // <1 → same distance change moves font less (harder to slam min/max).
          var gain = 0.42;
          var startDist = 0, startPt = basePt, lastPt = basePt, active = false;
          var lastHudAt = 0;

          function clampPt(pt){
            return Math.max(minPt, Math.min(maxPt, pt));
          }
          function snapPt(pt){
            return clampPt(Math.round(pt / step) * step);
          }
          function readPt(){
            var v = (getComputedStyle(document.documentElement).getPropertyValue('--USER__fontSize') || '').trim();
            if (v && v.charAt(v.length-1) === '%') {
              var n = parseFloat(v);
              if (!isNaN(n) && n > 0) return snapPt(18 * (n / 100));
            }
            return snapPt(basePt);
          }
          function dist(touches){
            var a = touches[0], b = touches[1];
            var dx = a.clientX - b.clientX, dy = a.clientY - b.clientY;
            return Math.sqrt(dx*dx + dy*dy) || 1;
          }
          function post(phase, pt){
            try { webkit.messageHandlers.connectsFontPinch.postMessage({phase: phase, pt: pt}); } catch(e) {}
          }
          function withPageWindow(fn){
            try {
              var w = window.__connectsPageWindow;
              if (w && typeof w[fn] === 'function') w[fn]();
            } catch (e) {}
          }
          // Same formula as native readiumFontScale(pt): percent = (pt/18)*100. No zoom.
          function applyFont(pt){
            pt = snapPt(pt);
            if (Math.abs(pt - lastPt) < 0.05) {
              lastPt = pt;
              return pt;
            }
            lastPt = pt;
            var p = ((pt / 18) * 100).toFixed(5) + '%';
            var r = document.documentElement;
            r.style.setProperty('--USER__fontSize', p, 'important');
            r.style.setProperty('font-size', p, 'important');
            return pt;
          }
          function hudMaybe(pt){
            var now = Date.now();
            if (now - lastHudAt < 80) return;
            lastHudAt = now;
            post('changed', Math.round(pt));
          }

          document.addEventListener('touchstart', function(e){
            if (e.touches.length !== 2) return;
            active = true;
            withPageWindow('prepareForPinch');
            startDist = dist(e.touches);
            startPt = readPt();
            lastPt = startPt;
            lastHudAt = 0;
            post('began', Math.round(startPt));
          }, {capture:true, passive:true});

          document.addEventListener('touchmove', function(e){
            if (!active || e.touches.length < 2) return;
            e.preventDefault();
            var ratio = dist(e.touches) / startDist;
            // Linear damp: 1+(ratio-1)*gain — small pinches barely move; need ~2.4× stretch for 2× size.
            var raw = startPt * (1 + (ratio - 1) * gain);
            var pt = applyFont(raw);
            hudMaybe(pt);
          }, {capture:true, passive:false});

          function end(phase){
            if (!active) return;
            active = false;
            lastPt = snapPt(lastPt);
            basePt = lastPt;
            withPageWindow('restoreAfterPinch');
            post(phase || 'ended', Math.round(lastPt));
          }
          document.addEventListener('touchend', function(e){
            if (e.touches.length < 2) end('ended');
          }, {capture:true, passive:true});
          document.addEventListener('touchcancel', function(){ end('cancelled'); }, {capture:true, passive:true});
        })();
        """
    }

    @objc private func systemThemeChanged() {
        applyChromeColors()
        updateAppearanceButton()
        contentsTable.reloadData()
    }

    @objc private func readerThemeChanged() {
        updateAppearanceButton()
        applyEPUBPreferences()
        contentsTable.reloadData()
    }

    /// Safety: ensure full chapter DOM before TOC / locator navigation.
    private func restorePageWindowAfterPinch() async {
        _ = await epubNavigator?.evaluateJavaScript("""
        (function(){
          try {
            if (window.__connectsPageWindow && window.__connectsPageWindow.restoreAfterPinch) {
              window.__connectsPageWindow.restoreAfterPinch();
            }
          } catch (e) {}
        })();
        """)
    }

    /// Only restore when still truncated — avoids extra work on every page turn.
    private func restorePageWindowIfTruncated() async {
        guard let nav = epubNavigator else { return }
        let result = await nav.evaluateJavaScript("""
        (function(){
          try {
            var w = window.__connectsPageWindow;
            if (!w || typeof w.isTruncated !== 'function') return false;
            if (!w.isTruncated()) return false;
            if (typeof w.restoreAfterPinch === 'function') w.restoreAfterPinch();
            return true;
          } catch (e) { return false; }
        })();
        """)
        _ = result
    }

    private func preparePageWindowForPinch() async {
        _ = await epubNavigator?.evaluateJavaScript("""
        (function(){
          try {
            if (window.__connectsPageWindow && window.__connectsPageWindow.prepareForPinch) {
              window.__connectsPageWindow.prepareForPinch();
            }
          } catch (e) {}
        })();
        """)
    }

    // MARK: - Annotations

    /// Locators from selection often carry a `cssSelector` that scopes TextQuote
    /// to a node Readium's CSS rewrite no longer matches → `rangeFromLocator`
    /// returns null and the decoration is silently dropped (no paint, no tap).
    /// Keep `text.highlight` + progression; drop brittle before/after context.
    private static func decorationLocator(from locator: Locator) -> Locator {
        locator.copy(
            locations: { locations in
                // cssSelector from selection often fails after Readium CSS rewrite.
                locations.cssSelector = nil
            },
            text: { text in
                if text.before?.isEmpty == true { text.before = nil }
                if text.after?.isEmpty == true { text.after = nil }
            }
        )
    }

    /// Push every annotation of the visible resource into the in-page painter.
    /// No Readium decorations: their TextQuote lookup silently failed on rewritten
    /// CSS and scanned the whole chapter per annotation.
    ///
    /// `forHREF` overrides which resource to paint for. During a jump the
    /// navigator's `currentLocation` is stale — Readium debounces it ~300ms after
    /// the scroll — so filtering by it dropped the very annotation being jumped to
    /// and nothing was ever painted to measure.
    /// `alwaysInclude` forces one annotation into the payload whatever the href
    /// filter thinks. During a jump, an href that fails the rough match would
    /// otherwise drop the only annotation we are trying to reach, and `setAll`
    /// replaces the whole set — so the target would be erased from the page.
    @discardableResult
    private func syncAnnotationsToPage(
        forHREF href: AnyURL? = nil,
        alwaysInclude forcedID: String? = nil
    ) async -> (sent: Int, attached: Int) {
        guard let nav = epubNavigator, !isFontPinching else { return (0, 0) }
        let currentHREF = href ?? nav.currentLocation?.href
        let payload: [[String: Any]] = epubAnnotations.compactMap { ann in
            if ann.id == forcedID { return Self.painterPayload(for: ann) }
            guard let href = Self.href(ofAnnotation: ann) else { return nil }
            if let currentHREF, !Self.hrefRoughlyMatches(href, currentHREF) { return nil }
            return Self.painterPayload(for: ann)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return (0, 0) }
        let attached = await nav.evaluateJavaScript("""
        (function(){
          try {
            if (!window.__connectsAnn) return -1;
            return window.__connectsAnn.setAll(\(json));
          } catch (e) { return -2; }
        })();
        """)
        return (payload.count, ((try? attached.get()) as? Int) ?? -3)
    }

    private static func painterPayload(for ann: ReadingAnnotation) -> [String: Any] {
        var dict: [String: Any] = [
            "id": ann.id,
            "color": (ann.color ?? .blue).rawValue,
        ]
        if let quote = ann.quote { dict["quote"] = quote }
        if let start = ann.textStart, let end = ann.textEnd, end > start {
            dict["start"] = start
            dict["end"] = end
        }
        return dict
    }

    private static func href(ofAnnotation ann: ReadingAnnotation) -> AnyURL? {
        guard let json = ann.locatorJSON,
              let locator = try? Locator(jsonString: json)
        else { return nil }
        return locator.href
    }

    /// Paint one annotation immediately, without rebuilding the whole page set.
    @discardableResult
    private func addAnnotationToPage(_ ann: ReadingAnnotation) async -> Bool {
        guard let nav = epubNavigator else { return false }
        guard let data = try? JSONSerialization.data(withJSONObject: Self.painterPayload(for: ann)),
              let json = String(data: data, encoding: .utf8)
        else { return false }
        return await jsBool("""
        (function(){
          try {
            if (!window.__connectsAnn) return false;
            return window.__connectsAnn.add(\(json));
          } catch (e) { return false; }
        })();
        """, via: nav)
    }

    /// Quote a Swift string for embedding in a JS snippet.
    ///
    /// `JSONSerialization` treats a bare string as an invalid top-level type and
    /// raises an Objective-C exception, which `try?` cannot catch — passing an
    /// annotation id straight to it terminated the app.
    private static func jsStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return json
    }

    private func removeAnnotationFromPage(id: String) {
        guard let nav = epubNavigator else { return }
        let json = Self.jsStringLiteral(id)
        Task { @MainActor in
            _ = await nav.evaluateJavaScript("""
            (function(){
              try { return window.__connectsAnn ? window.__connectsAnn.remove(\(json)) : false; }
              catch (e) { return false; }
            })();
            """)
        }
    }

    /// Character offsets of the stashed selection inside the resource text.
    private func captureSelectionOffsets() async -> (start: Int, end: Int, quote: String)? {
        guard let nav = epubNavigator else { return nil }
        let result = await nav.evaluateJavaScript("""
        (function(){
          try {
            if (!window.__connectsAnn) return null;
            return window.__connectsAnn.capture();
          } catch (e) { return null; }
        })();
        """)
        guard case let .success(value) = result,
              let dict = value as? [String: Any],
              let start = (dict["start"] as? NSNumber)?.intValue,
              let end = (dict["end"] as? NSNumber)?.intValue,
              end > start
        else { return nil }
        return (start, end, (dict["quote"] as? String) ?? "")
    }

    /// Selection locators and currentLocation often differ by leading slash / path prefix.
    private static func hrefRoughlyMatches(_ a: AnyURL, _ b: AnyURL) -> Bool {
        if a.isEquivalentTo(b) { return true }
        let as_ = a.string.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let bs = b.string.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if as_ == bs { return true }
        if as_.hasSuffix(bs) || bs.hasSuffix(as_) { return true }
        let aLast = as_.split(separator: "/").last.map(String.init) ?? as_
        let bLast = bs.split(separator: "/").last.map(String.init) ?? bs
        return !aLast.isEmpty && aLast == bLast
    }

    private func jsBool(_ script: String, via nav: EPUBNavigatorViewController) async -> Bool {
        let result = await nav.evaluateJavaScript(script)
        if case let .success(value) = result {
            if let b = value as? Bool { return b }
            if let n = value as? NSNumber { return n.boolValue }
        }
        return false
    }

    /// Set JS commit lock immediately (no await) so scroll dismiss cannot race the color tap.
    private func armHighlightCommitLockSync() {
        isCommittingHighlight = true
        let js = "window.__connectsHLLock=true;window.__connectsBarVisible=false;"
        (findEPUBWebView() as? WKWebView)?.evaluateJavaScript(js, completionHandler: nil)
        Task { @MainActor in
            _ = await self.epubNavigator?.evaluateJavaScript(js)
        }
    }

    private func releaseHighlightCommitLock() async {
        guard let nav = epubNavigator else { return }
        _ = await nav.evaluateJavaScript("""
        (function(){ window.__connectsHLLock = false; })();
        """)
    }

    private func persistAnnotations(reloadContents: Bool = true) {
        // Always the *source* Study/Files URL — never the live ConnectsEPUB/cached-*.epub.
        // Cache is marked stale on save; next open re-copies. Live WK keeps the pinned cache.
        guard let url = sourceEPUBURL else { return }
        _ = EPUBAnnotationStore.save(
            epubAnnotations,
            epubURL: url,
            documentID: currentDocumentID,
            deletedIDs: deletedAnnotationIDs
        )
        // Caller may be mid swipe-delete (`deleteRows`) — never reload then.
        if reloadContents, isContentsPanelVisible {
            contentsTable.reloadData()
        }
        annotationsNeedPackageFlush = true
    }

    /// Copy the annotations into the book file itself, so they survive being
    /// AirDropped/synced elsewhere. Repacking is far too heavy to do per highlight,
    /// so it happens once, off the main thread, when the reader is done with the book.
    private func flushAnnotationsToPackage() {
        guard annotationsNeedPackageFlush, let url = sourceEPUBURL else { return }
        annotationsNeedPackageFlush = false
        let annotations = epubAnnotations
        let deleted = deletedAnnotationIDs
        Task.detached(priority: .utility) {
            _ = EPUBAnnotationStore.flushToPackage(annotations, epubURL: url, deletedIDs: deleted)
        }
    }

    /// System UIMenuController custom items are unreliable on modern iOS.
    /// Suppress the system menu; selection UI comes from `didChangeSelection` / JS hook.
    func navigator(_ navigator: SelectableNavigator, shouldShowMenuForSelection selection: Selection) -> Bool {
        // Arm immediately — returning false often collapses the native selection,
        // so the DOM Range must be frozen before the menu decision returns.
        pendingSelection = selection
        pendingLocatorJSON = try? selection.locator.jsonString()
        pendingQuote = selection.locator.text.highlight
        if let frame = selection.frame, frame.width > 1, frame.height > 1 {
            pendingAnchorFrame = frame
        }
        Task { @MainActor in await self.stashSelectionRange() }
        scheduleHighlightPicker(for: selection)
        return false
    }

    func navigator(_ navigator: EPUBNavigatorViewController, didChangeSelection selection: Selection?) {
        guard engineKind == .epub else { return }
        guard let selection else {
            // Native selection collapsed. If the bar is already up (or pending),
            // a blank tap / swipe should dismiss — do not keep chrome forever.
            // Color-commit sets isCommittingHighlight first so stash survives the tap.
            if !isCommittingHighlight, highlightPickerOverlay != nil {
                dismissSelectionChrome(clearNativeSelection: false)
            }
            return
        }
        if ConnectsNoteSheet.isVisible { return }
        pendingSelection = selection
        pendingLocatorJSON = try? selection.locator.jsonString()
        pendingQuote = selection.locator.text.highlight
        if let frame = selection.frame, frame.width > 1, frame.height > 1 {
            pendingAnchorFrame = frame
        }
        scheduleHighlightPicker(for: selection)
    }

    func navigator(_ navigator: SelectableNavigator, canPerformAction action: EditingAction, for selection: Selection) -> Bool {
        true
    }

    /// Tap empty page while the color bar is visible → dismiss like cancelling selection.
    /// Highlight taps are hit-tested in the page painter, which posts `openNote`.
    func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
        guard engineKind == .epub else { return }
        guard !ConnectsNoteSheet.isVisible else { return }
        guard !isCommittingHighlight else { return }
        if highlightPickerOverlay != nil {
            dismissSelectionChrome(clearNativeSelection: true)
        }
    }

    private func presentNoteEditor(forAnnotationID id: String) {
        let ann = epubAnnotations.first(where: { $0.id == id })
            ?? epubAnnotations.first(where: { id.hasSuffix($0.id) || id.contains($0.id) })
        guard let ann else { return }
        let id = ann.id
        // Same ConnectsNoteSheet chrome as PDF / EPUB footnotes (translucent; blank dismisses).
        ConnectsNoteSheet.present(
            from: self,
            title: "",
            message: nil,
            initialText: ann.title,
            confirmTitle: "保存",
            deleteTitle: "删除",
            onSave: { [weak self] title in
                guard let self,
                      let idx = self.epubAnnotations.firstIndex(where: { $0.id == id })
                else { return }
                self.epubAnnotations[idx].title = title
                self.epubAnnotations[idx].updatedAt = Date()
                self.persistAnnotations()
                if self.isContentsPanelVisible {
                    self.contentsTable.reloadData()
                }
            },
            onDelete: { [weak self] in
                guard let self else { return }
                self.epubAnnotations.removeAll { $0.id == id }
                self.deletedAnnotationIDs.insert(id)
                self.persistAnnotations()
                self.removeAnnotationFromPage(id: id)
            },
            onCancel: nil
        )
    }

    /// Hide color bar + clear pending + optionally clear WK selection / JS stash.
    private func dismissSelectionChrome(clearNativeSelection: Bool) {
        selectionPickerWork?.cancel()
        selectionPickerWork = nil
        hideHighlightPicker()
        pendingSelection = nil
        pendingLocatorJSON = nil
        pendingQuote = nil
        pendingAnchorFrame = nil
        pendingSelectionRects = []
        pendingSelectionScroll = .zero
        Task { @MainActor in
            await self.clearStashedSelectionRange()
            if let nav = self.epubNavigator {
                _ = await nav.evaluateJavaScript("window.__connectsBarVisible = false;")
            }
        }
        if clearNativeSelection {
            epubNavigator?.clearSelection()
        }
    }

    private func scheduleHighlightPicker(for selection: Selection) {
        selectionPickerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.highlightPickerOverlay != nil || ConnectsNoteSheet.isVisible { return }
            let live = self.epubNavigator?.currentSelection ?? self.pendingSelection ?? selection
            self.pendingSelection = live
            self.pendingLocatorJSON = (try? live.locator.jsonString()) ?? self.pendingLocatorJSON
            self.pendingQuote = live.locator.text.highlight ?? self.pendingQuote
            if let frame = live.frame, frame.width > 1, frame.height > 1 {
                self.pendingAnchorFrame = frame
            }
            // Locator was already captured on selection — show the color bar.
            guard self.highlightPickerOverlay == nil, !ConnectsNoteSheet.isVisible else { return }
            self.presentHighlightPicker(
                quote: self.pendingQuote ?? live.locator.text.highlight,
                anchorInNavigator: self.pendingAnchorFrame ?? live.frame
            )
        }
        selectionPickerWork = work
        // Debounce until selection settles after the finger lifts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func presentHighlightPicker(quote: String?, anchorInNavigator: CGRect?) {
        hideHighlightPicker()
        // Selection.frame is already in navigator view space — host the bar there
        // so it sits flush above the highlighted span.
        let host = epubNavigator?.view ?? contentHost
        host.layoutIfNeeded()

        Task { @MainActor in
            if let nav = self.epubNavigator {
                _ = await nav.evaluateJavaScript("window.__connectsBarVisible = true;")
            }
        }

        // Invisible full-host catcher: selection is often already cleared when the bar
        // appears (menu suppressed), so a second blank tap never fires didChangeSelection.
        let dim = UIControl(frame: host.bounds)
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.backgroundColor = .clear
        dim.addTarget(self, action: #selector(highlightPickerDimTapped), for: .touchUpInside)
        host.addSubview(dim)
        highlightPickerDim = dim

        let bar = ConnectsHighlightPickerOverlay()
        bar.translatesAutoresizingMaskIntoConstraints = true
        bar.backgroundColor = DSTheme.c.surface
        bar.layer.cornerRadius = 8
        bar.layer.shadowColor = UIColor.black.cgColor
        bar.layer.shadowOpacity = 0.16
        bar.layer.shadowRadius = 5
        bar.layer.shadowOffset = CGSize(width: 0, height: 1)
        bar.clipsToBounds = false

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fillEqually
        stack.spacing = 6

        func colorButton(title: String, kind: ReadingAnnotation.ColorKind, tag: Int) -> UIButton {
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
            b.tintColor = ReadingAnnotationStyle.epubDot(kind)
            b.backgroundColor = ReadingAnnotationStyle.epubTint(kind)
            b.layer.cornerRadius = 6
            b.tag = tag
            b.addTarget(self, action: #selector(highlightPickerColorTapped(_:)), for: .touchUpInside)
            return b
        }

        let blue = colorButton(title: "浅蓝", kind: .blue, tag: 1)
        let green = colorButton(title: "浅绿", kind: .green, tag: 2)

        let close = UIButton(type: .system)
        close.setTitle("✕", for: .normal)
        close.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        close.tintColor = DSTheme.c.textSecondary
        close.addTarget(self, action: #selector(highlightPickerDimTapped), for: .touchUpInside)

        stack.addArrangedSubview(blue)
        stack.addArrangedSubview(green)
        bar.addSubview(stack)
        bar.addSubview(close)
        close.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(bar)
        highlightPickerOverlay = bar
        host.bringSubviewToFront(bar)

        let barH: CGFloat = 32
        let barW: CGFloat = 152
        let gap: CGFloat = 6

        let a: CGRect = {
            if let f = anchorInNavigator ?? pendingAnchorFrame, f.width > 1, f.height > 1 {
                return f
            }
            return CGRect(
                x: host.bounds.midX - 40,
                y: max(40, host.bounds.midY - 20),
                width: 80,
                height: 16
            )
        }()

        var x = a.midX - barW / 2
        x = max(6, min(x, host.bounds.width - barW - 6))
        var y = a.minY - barH - gap
        if y < 4 {
            y = min(a.maxY + gap, max(4, host.bounds.height - barH - 4))
        }

        bar.frame = CGRect(x: x, y: y, width: barW, height: barH)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 5),
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -4),
            stack.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -2),

            close.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -2),
            close.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 26),
            close.heightAnchor.constraint(equalToConstant: 24),
        ])

        bar.alpha = 0
        bar.transform = CGAffineTransform(translationX: 0, y: 3)
        UIView.animate(withDuration: 0.14, delay: 0, options: [.curveEaseOut]) {
            bar.alpha = 1
            bar.transform = .identity
        }
    }

    /// Keep a DOM Range while the color bar is up (selection often collapses after menu suppress).
    private func stashSelectionRange() async {
        guard let nav = epubNavigator else { return }
        _ = await nav.evaluateJavaScript("""
        (function(){
          try {
            var sel = window.getSelection && window.getSelection();
            if (sel && sel.rangeCount > 0 && !sel.isCollapsed) {
              window.__connectsSavedRange = sel.getRangeAt(0).cloneRange();
              window.__connectsSavedText = (sel.toString() || '').replace(/\\s+/g, ' ').trim();
              return true;
            }
            return !!window.__connectsSavedRange;
          } catch (e) { return false; }
        })();
        """)
    }

    private func clearStashedSelectionRange() async {
        guard let nav = epubNavigator else { return }
        _ = await nav.evaluateJavaScript("""
        (function(){ window.__connectsSavedRange = null; window.__connectsSavedText = null; })();
        """)
    }

    @objc private func highlightPickerDimTapped() {
        dismissSelectionChrome(clearNativeSelection: true)
    }

    private func hideHighlightPicker() {
        selectionPickerWork?.cancel()
        selectionPickerWork = nil
        if let dim = highlightPickerDim {
            highlightPickerDim = nil
            dim.removeFromSuperview()
        }
        Task { @MainActor in
            if let nav = self.epubNavigator {
                _ = await nav.evaluateJavaScript("window.__connectsBarVisible = false;")
            }
        }
        guard let overlay = highlightPickerOverlay else { return }
        highlightPickerOverlay = nil
        UIView.animate(withDuration: 0.12, animations: {
            overlay.alpha = 0
        }, completion: { _ in
            overlay.removeFromSuperview()
        })
    }

    @objc private func highlightPickerColorTapped(_ sender: UIButton) {
        let color: ReadingAnnotation.ColorKind = sender.tag == 2 ? .green : .blue
        armHighlightCommitLockSync()
        Task { @MainActor in
            await self.stashSelectionRange()
            self.hideHighlightPicker()
            self.beginHighlightFromSelection(color: color)
        }
    }

    @objc private func highlightSelectionBlue() {
        armHighlightCommitLockSync()
        Task { @MainActor in
            await self.stashSelectionRange()
            self.beginHighlightFromSelection(color: .blue)
        }
    }

    @objc private func highlightSelectionGreen() {
        armHighlightCommitLockSync()
        Task { @MainActor in
            await self.stashSelectionRange()
            self.beginHighlightFromSelection(color: .green)
        }
    }

    /// Commit: capture text offsets → persist → paint. Nothing here mutates the
    /// page DOM, so the live WebKit selection can stay alive until the very end.
    private func beginHighlightFromSelection(color: ReadingAnnotation.ColorKind) {
        isCommittingHighlight = true
        guard let nav = epubNavigator else {
            isCommittingHighlight = false
            Task { @MainActor in await self.releaseHighlightCommitLock() }
            return
        }

        let selection = pendingSelection ?? nav.currentSelection
        let locator: Locator? = {
            if let selection { return selection.locator }
            if let json = pendingLocatorJSON, let loc = try? Locator(jsonString: json) { return loc }
            if let q = pendingQuote ?? selection?.locator.text.highlight,
               let base = nav.currentLocation {
                return Self.locatorFromQuoteFallback(base: base, quote: q)
            }
            return nil
        }()

        func bail() {
            ConnectsToast.show("请先划选一段文字", in: view, duration: 1.2)
            isCommittingHighlight = false
            Task { @MainActor in await self.releaseHighlightCommitLock() }
            dismissSelectionChrome(clearNativeSelection: true)
        }

        guard let locator,
              let highlightText = locator.text.highlight?.trimmingCharacters(in: .whitespacesAndNewlines),
              !highlightText.isEmpty
        else {
            bail()
            return
        }

        var deco = Self.decorationLocator(from: locator)
        if deco.locations.progression == nil {
            let prog = selection?.locator.locations.progression
                ?? nav.currentLocation?.locations.progression
            if let prog {
                deco = deco.copy(locations: { $0.progression = prog })
            }
        }
        guard let locatorJSON = try? deco.jsonString() else {
            bail()
            return
        }

        pendingSelection = nil
        pendingLocatorJSON = nil
        pendingQuote = nil
        pendingAnchorFrame = nil
        pendingSelectionRects = []
        pendingSelectionScroll = .zero

        hideHighlightPicker()

        Task { @MainActor in
            defer {
                self.isCommittingHighlight = false
                Task { @MainActor in await self.releaseHighlightCommitLock() }
            }
            let captured = await self.captureSelectionOffsets()
            var ann = ReadingAnnotation(
                id: UUID().uuidString,
                title: "",
                createdAt: Date(),
                updatedAt: Date(),
                color: color,
                locatorJSON: locatorJSON,
                quote: captured.map { $0.quote.isEmpty ? highlightText : $0.quote } ?? highlightText,
                textStart: captured?.start,
                textEnd: captured?.end,
                pageIndex: nil,
                boundsX: nil,
                boundsY: nil,
                boundsW: nil,
                boundsH: nil
            )
            if ann.quote?.isEmpty != false { ann.quote = highlightText }

            // List it before painting. A locationDidChange sync that races the
            // clearSelection below used to call setAll without this id and wipe
            // the just-added underline.
            self.epubAnnotations.append(ann)

            var painted = await self.addAnnotationToPage(ann)
            if !painted {
                // One more try via the full-chapter sync path.
                let sync = await self.syncAnnotationsToPage(alwaysInclude: ann.id)
                painted = sync.attached > 0
            }
            nav.clearSelection()
            await self.clearStashedSelectionRange()

            // Record the page it landed on now, while it is on screen, so a later
            // jump is a single navigator move instead of a search.
            if painted {
                let measured = await self.measureAnnotationInPage(id: ann.id)
                if measured.isResolved, measured.visible {
                    _ = self.applyProgression(measured.progression, to: ann.id)
                }
            }
            self.persistAnnotations()
            if !painted {
                ConnectsToast.show("高亮已保存，但当前页未画上", in: self.view, duration: 1.4)
            }
        }
    }

    private func refreshContentsPanelChrome() {
        contentsTitleButton.setTitle("\(contentsPanelTab.title) ▾", for: .normal)
        contentsTitleButton.accessibilityLabel = contentsPanelTab.title
    }

    @objc private func contentsSwitchTapped() {
        contentsPanelTab = contentsPanelTab.next
        refreshContentsPanelChrome()
        contentsTable.reloadData()
    }

    @objc private func contentsTapped() {
        if isContentsPanelVisible { hideContentsPanel() } else { showContentsPanel() }
    }

    private func showContentsPanel() {
        isContentsPanelVisible = true
        contentsDim.isHidden = false
        contentsDim.alpha = 0
        contentsTable.allowsSelection = true
        refreshContentsPanelChrome()
        contentsTable.reloadData()
        view.bringSubviewToFront(contentsDim)
        view.bringSubviewToFront(contentsPanelHost)
        view.layoutIfNeeded()
        UIView.animate(withDuration: 0.22) {
            self.contentsDim.alpha = 1
            self.contentsPanelTrailing.constant = 0
            self.view.layoutIfNeeded()
        }
    }

    @objc private func hideContentsPanel() {
        isContentsPanelVisible = false
        UIView.animate(withDuration: 0.2, animations: {
            self.contentsDim.alpha = 0
            self.contentsPanelTrailing.constant = self.contentsPanelWidthConstant
            self.view.layoutIfNeeded()
        }, completion: { _ in
            self.contentsDim.isHidden = true
        })
    }

    // MARK: - NavigatorDelegate

    /// contentHost already sits under our Study top bar (past the status bar).
    /// Readium’s default path re-applies window.safeAreaInsets.top and leaves a
    /// large blank band under the chrome — override with our reading insets only.
    func navigatorContentInset(_ navigator: VisualNavigator) -> UIEdgeInsets? {
        let pad = Self.readingContentInsets
        return UIEdgeInsets(top: pad.top, left: 0, bottom: pad.bottom, right: 0)
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        lastLocatorJSON = try? locator.jsonString()
        resolveFirstEPUBLocationWait(success: true)
        refreshTitleChrome()
        scheduleProgressSave()
        onPageChanged?()
        // Page turn / spread change — selection chrome must not linger across pages.
        if !isCommittingHighlight,
           highlightPickerOverlay != nil || pendingSelection != nil || pendingLocatorJSON != nil {
            dismissSelectionChrome(clearNativeSelection: true)
        }
        // If pinch left the chapter DOM truncated, restore before the user notices a
        // full-chapter rebuild mid page-turn — then repaint so CSS highlights are not
        // left pointing at detached nodes (that is what made brand-new underlines vanish).
        markRestoreTask?.cancel()
        markRestoreTask = Task { @MainActor in
            if !self.isJumpingToAnnotation {
                await self.restorePageWindowIfTruncated()
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled,
                  !self.isFontPinching,
                  !self.isCommittingHighlight,
                  !self.isJumpingToAnnotation
            else { return }
            await self.syncAnnotationsToPage()
        }
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        ConnectsToast.show(String(describing: error), in: view, duration: 2.0)
    }

    func navigator(_ navigator: Navigator, didFailToLoadResourceAt href: RelativeURL, withError error: ReadError) {
        // Do not abort first-paint wait — CSS/image failures are common and not fatal.
        ConnectsToast.show("页面资源加载失败：\(href.string)", in: view, duration: 1.6)
    }

    /// Footnote / index markers like `[1]` — show content in a sheet, don't jump.
    func navigator(
        _ navigator: Navigator,
        shouldNavigateToNoteAt link: Link,
        content: String,
        referrer: String?
    ) -> Bool {
        presentFootnotePopup(html: content, referrerHTML: referrer)
        return false
    }

    private weak var footnoteOverlay: UIView?
    private weak var footnoteTextView: UITextView?
    private var footnoteIsAwaitingContent = false
    private var footnoteTimeoutTask: Task<Void, Never>?

    /// Show the card the moment a `[1]` marker is tapped.
    ///
    /// Resolving the note goes through Readium, which refetches and reparses the
    /// whole target chapter — hundreds of KB in this book — so the card used to
    /// appear long after the tap and the marker felt unresponsive.
    private func presentFootnotePlaceholder() {
        guard footnoteOverlay == nil else { return }
        // Set the flag after presenting: building the card clears any previous one,
        // which resets this.
        presentFootnotePopup(html: "", referrerHTML: nil, placeholder: true)
        footnoteIsAwaitingContent = true
        // `[1]`-shaped links are matched heuristically, so some taps never produce a
        // note. Do not leave a card stuck on 载入中.
        footnoteTimeoutTask?.cancel()
        footnoteTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, self.footnoteIsAwaitingContent else { return }
            self.dismissFootnotePopup(animated: true)
        }
    }

    private func presentFootnotePopup(
        html: String,
        referrerHTML: String?,
        placeholder: Bool = false
    ) {
        _ = referrerHTML
        var body = placeholder ? "载入中…" : Self.plainText(fromHTML: html)
        // Drop leading [n] marker — popup shows note body only.
        if !placeholder, let m = body.range(of: #"^\[\d+\]\s*"#, options: .regularExpression) {
            body = String(body[m.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !body.isEmpty else {
            if footnoteIsAwaitingContent { dismissFootnotePopup(animated: true) }
            footnoteIsAwaitingContent = false
            ConnectsToast.show("未找到注释内容", in: view, duration: 1.2)
            return
        }
        // Content arrived for a card already on screen — swap the text in place so
        // the popup does not flicker away and back.
        if !placeholder, footnoteIsAwaitingContent, let existing = footnoteTextView {
            footnoteIsAwaitingContent = false
            footnoteTimeoutTask?.cancel()
            existing.text = body
            return
        }

        dismissFootnotePopup(animated: false)

        let container: UIView = {
            var node: UIView? = view
            while let cur = node {
                if cur is StudyShellRootViewMarker { return cur }
                node = cur.superview
            }
            return view!
        }()

        let overlay = UIView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = .clear

        let backdrop = UIControl()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.backgroundColor = ConnectsReaderPopupStyle.dimColor
        backdrop.addTarget(self, action: #selector(dismissFootnotePopupFast), for: .touchDown)

        let cardWidth = ConnectsReaderPopupStyle.cardWidth(in: container)
        let cardHeight = ConnectsReaderPopupStyle.cardHeight(in: container)

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        ConnectsReaderPopupStyle.applyCardChrome(card)
        card.isUserInteractionEnabled = true
        card.tag = 90421

        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.showsVerticalScrollIndicator = true
        textView.textContainerInset = ConnectsReaderPopupStyle.textInset
        textView.font = ConnectsReaderPopupStyle.bodyFont
        textView.textColor = ConnectsReaderPopupStyle.bodyTextColor
        textView.text = body
        textView.dataDetectorTypes = []

        card.addSubview(textView)
        overlay.addSubview(backdrop)
        overlay.addSubview(card)
        container.addSubview(overlay)
        footnoteOverlay = overlay
        footnoteTextView = textView

        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            backdrop.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: overlay.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),

            card.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: cardWidth),
            card.heightAnchor.constraint(equalToConstant: cardHeight),

            textView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            textView.topAnchor.constraint(equalTo: card.topAnchor),
            textView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        textView.setContentOffset(.zero, animated: false)
        overlay.alpha = 0
        card.alpha = 0
        card.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
        UIView.animate(withDuration: 0.14, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            overlay.alpha = 1
            card.alpha = 1
            card.transform = .identity
        }
    }

    @objc private func dismissFootnotePopupFast() {
        dismissFootnotePopup(animated: true)
    }

    @objc private func dismissFootnotePopup() {
        dismissFootnotePopup(animated: true)
    }

    private func dismissFootnotePopup(animated: Bool) {
        footnoteIsAwaitingContent = false
        footnoteTimeoutTask?.cancel()
        guard let overlay = footnoteOverlay else { return }
        footnoteOverlay = nil
        let finish = { overlay.removeFromSuperview() }
        if animated {
            UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
                overlay.alpha = 0
            } completion: { _ in
                finish()
            }
        } else {
            finish()
        }
    }

    /// Lightweight HTML → plain text (no WebKit / NSAttributedString on the tap path).
    private static func plainText(fromHTML html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)</p\s*>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)</div\s*>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)</li\s*>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&ldquo;", "“"), ("&rdquo;", "”"), ("&lsquo;", "‘"), ("&rsquo;", "’"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
        ]
        for (e, r) in entities {
            s = s.replacingOccurrences(of: e, with: r)
        }
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - TOC / annotations table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard engineKind == .epub else { return 0 }
        switch contentsPanelTab {
        case .outline:
            return max(tocLinks.count, 1)
        case .annotations:
            return max(epubAnnotations.count, 1)
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ch", for: indexPath)
        cell.imageView?.image = nil
        cell.textLabel?.numberOfLines = 2
        cell.textLabel?.font = UIFont.systemFont(ofSize: 13)
        cell.backgroundColor = DSTheme.c.surface
        guard engineKind == .epub else {
            cell.textLabel?.text = nil
            cell.selectionStyle = .none
            return cell
        }

        switch contentsPanelTab {
        case .outline:
            if !tocLinks.isEmpty {
                let link = tocLinks[indexPath.row]
                cell.textLabel?.text = link.title ?? link.url().string
                cell.textLabel?.textColor = DSTheme.c.textPrimary
                cell.selectionStyle = .default
                cell.isUserInteractionEnabled = true
            } else {
                cell.textLabel?.text = "暂无目录"
                cell.textLabel?.textColor = DSTheme.c.textSecondary
                cell.selectionStyle = .none
                cell.isUserInteractionEnabled = false
            }
        case .annotations:
            if !epubAnnotations.isEmpty {
                let ann = epubAnnotations[indexPath.row]
                let title = ann.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty {
                    cell.textLabel?.text = ann.displayTitle
                    cell.textLabel?.textColor = DSTheme.c.textSecondary
                } else {
                    cell.textLabel?.text = title
                    cell.textLabel?.textColor = DSTheme.c.textPrimary
                }
                let color = ann.color ?? .blue
                let cfg = UIImage.SymbolConfiguration(pointSize: 8, weight: .regular)
                cell.imageView?.image = UIImage(systemName: "circle.fill", withConfiguration: cfg)?
                    .withTintColor(ReadingAnnotationStyle.epubDot(color), renderingMode: .alwaysOriginal)
                cell.selectionStyle = .default
                cell.isUserInteractionEnabled = true
            } else {
                cell.textLabel?.text = "暂无标注"
                cell.textLabel?.textColor = DSTheme.c.textSecondary
                cell.selectionStyle = .none
                cell.isUserInteractionEnabled = false
            }
        }
        return cell
    }

    private var tocJumpGeneration: UInt = 0
    private var annotationJumpGeneration: UInt = 0
    /// Suppresses repaint / page-window churn while a sidebar jump is in flight.
    private var isJumpingToAnnotation = false
    private var annotationsNeedPackageFlush = false
    /// Deletions have to be recorded, not just applied — see `EPUBAnnotationStore`.
    private var deletedAnnotationIDs: Set<String> = []

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard engineKind == .epub else { return }

        switch contentsPanelTab {
        case .outline:
            guard tocLinks.indices.contains(indexPath.row) else { return }
            let link = tocLinks[indexPath.row]
            hideContentsPanel()
            tocJumpGeneration &+= 1
            let gen = tocJumpGeneration
            Task { @MainActor in
                let ok = await self.jumpToTOCLink(link, generation: gen)
                guard gen == self.tocJumpGeneration else { return }
                if !ok {
                    ConnectsToast.show("无法跳转到该章节", in: self.view, duration: 1.4)
                }
            }
        case .annotations:
            guard epubAnnotations.indices.contains(indexPath.row) else { return }
            let ann = epubAnnotations[indexPath.row]
            hideContentsPanel()
            annotationJumpGeneration &+= 1
            let gen = annotationJumpGeneration
            Task { @MainActor in
                await self.jumpToAnnotation(ann, generation: gen)
            }
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard engineKind == .epub,
              contentsPanelTab == .annotations,
              !epubAnnotations.isEmpty,
              epubAnnotations.indices.contains(indexPath.row)
        else { return nil }
        let id = epubAnnotations[indexPath.row].id
        let delete = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, done in
            guard let self else { done(false); return }
            guard let row = self.epubAnnotations.firstIndex(where: { $0.id == id }) else {
                done(false)
                return
            }
            // `numberOfRows` uses max(count, 1) for the empty placeholder — deleting the
            // last real row must reload that cell, not deleteRows (count stays 1).
            let becomingEmpty = self.epubAnnotations.count == 1
            self.epubAnnotations.remove(at: row)
            self.deletedAnnotationIDs.insert(id)
            // Do NOT reloadData here — that races swipe `deleteRows` and freezes the UI.
            self.persistAnnotations(reloadContents: false)
            if becomingEmpty {
                tableView.reloadRows(at: [indexPath], with: .fade)
            } else {
                tableView.deleteRows(at: [indexPath], with: .automatic)
            }
            done(true)
            self.removeAnnotationFromPage(id: id)
        }
        let config = UISwipeActionsConfiguration(actions: [delete])
        config.performsFirstActionWithFullSwipe = true
        return config
    }

    @MainActor
    private func jumpToAnnotation(_ ann: ReadingAnnotation, generation: UInt) async {
        guard generation == annotationJumpGeneration else { return }
        var trace = AnnotationJumpTrace(annotationID: ann.id)
        defer { trace.emit() }

        guard let json = ann.locatorJSON,
              let raw = try? Locator(jsonString: json),
              let nav = epubNavigator,
              let pub = publication
        else {
            trace.finish("no locator or navigator")
            ConnectsToast.show("无法跳转到该标注", in: view, duration: 1.2)
            return
        }
        markRestoreTask?.cancel()
        await restorePageWindowIfTruncated()
        guard generation == annotationJumpGeneration else { return }

        // `go(to:)` bails before moving when the href is not in the reading order,
        // which is why a few annotations never jumped from anywhere.
        guard let resolved = resolveJumpLocator(raw, in: pub, for: ann.id, trace: &trace) else {
            trace.finish("href unresolvable")
            ConnectsToast.show("该标注指向的章节不在这本书里", in: view, duration: 1.8)
            return
        }

        let locator = pub.normalizeLocator(resolved)
        let options = NavigatorGoOptions(animated: false)
        // Progression only. A fragment or `text.highlight` would take priority over
        // it inside Readium's spread view and send the jump somewhere else.
        let target = locator.copy(
            locations: { loc in
                loc.cssSelector = nil
                if !loc.fragments.isEmpty { loc.fragments = [] }
            },
            text: { text in
                text.highlight = nil
                text.before = nil
                text.after = nil
            }
        )

        isJumpingToAnnotation = true
        defer { isJumpingToAnnotation = false }

        // Hop 1 — get into the right resource. `true` here only means the navigator
        // accepted the request; it resolves before the scroll settles, so it is
        // never treated as success on its own.
        var accepted = false
        for attempt in 0 ..< 6 {
            guard generation == annotationJumpGeneration else { return }
            let ok = await nav.go(to: target, options: options)
            trace.go("resource", progression: target.locations.progression, accepted: ok)
            if ok {
                accepted = true
                break
            }
            try? await Task.sleep(nanoseconds: UInt64(80 + attempt * 40) * 1_000_000)
        }
        guard generation == annotationJumpGeneration else { return }
        guard accepted else {
            trace.finish("navigator refused every go")
            ConnectsToast.show("无法跳转到该标注", in: view, duration: 1.2)
            return
        }

        // Paint against the annotation's own href, never the debounced current one.
        let paint = await syncAnnotationsToPage(forHREF: target.href, alwaysInclude: ann.id)
        trace.painted("after go", sent: paint.sent, attached: paint.attached)
        trace.location(nav.currentLocation)

        // Wait for the range to exist and have geometry, rather than a fixed sleep.
        var measured = AnnotationMeasure(error: "not attempted")
        for attempt in 0 ..< 12 {
            guard generation == annotationJumpGeneration else { return }
            measured = await measureAnnotationInPage(id: ann.id)
            if measured.isResolved { break }
            try? await Task.sleep(nanoseconds: 80_000_000)
            // The resource may have finished swapping in only now.
            if attempt % 4 == 3 {
                let repaint = await syncAnnotationsToPage(forHREF: target.href, alwaysInclude: ann.id)
                trace.painted("retry \(attempt)", sent: repaint.sent, attached: repaint.attached)
            }
        }
        trace.measured("initial", measured)
        guard generation == annotationJumpGeneration else { return }
        guard measured.isResolved else {
            trace.finish("annotation never became measurable")
            ConnectsToast.show("未能在本章定位该标注", in: view, duration: 1.6)
            return
        }
        if measured.visible {
            persistProgression(measured.progression, for: ann.id)
            trace.finish("already on screen")
            return
        }

        // Hop 2 — move to the measured page, then confirm. A reading taken from real
        // geometry is absolute and retrying the same target is right: the failure is
        // timing, since Readium defers the location until the spread has loaded. An
        // `approx` reading is only a character-offset guess, so once the move lands
        // near it and real rects come back, re-aim at the corrected value.
        var aim = measured.progression
        for attempt in 0 ..< 3 {
            guard generation == annotationJumpGeneration else { return }
            let precise = target.copy(locations: { $0.progression = aim })
            let ok = await nav.go(to: precise, options: options)
            trace.go("precise", progression: aim, accepted: ok)
            try? await Task.sleep(nanoseconds: UInt64(120 + attempt * 80) * 1_000_000)
            guard generation == annotationJumpGeneration else { return }
            let after = await measureAnnotationInPage(id: ann.id)
            trace.measured("after-\(attempt)", after)
            trace.location(nav.currentLocation)
            if after.isResolved, after.visible {
                persistProgression(after.progression, for: ann.id)
                trace.finish("landed on attempt \(attempt)")
                return
            }
            if after.isResolved, !after.approx, abs(after.progression - aim) > 0.0005 {
                aim = after.progression
            }
        }

        // The navigator is in the right resource but will not stop on the right
        // page. Land on it directly from the highlight's own rect, skipping the
        // progression round-trip that keeps rounding to a neighbour.
        let landing = await scrollAnnotationIntoView(id: ann.id)
        trace.note("direct scroll: \(landing)")
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard generation == annotationJumpGeneration else { return }
        let final = await measureAnnotationInPage(id: ann.id)
        trace.measured("after-direct", final)
        trace.location(nav.currentLocation)
        if final.isResolved, final.visible {
            persistProgression(final.progression, for: ann.id)
            trace.finish("landed via direct scroll")
            return
        }
        trace.finish("moved but never became visible")
        ConnectsToast.show("跳转未能停在标注处", in: view, duration: 1.6)
    }

    /// Make sure the locator points at a resource this publication actually has.
    ///
    /// Annotations written by older builds (and any book whose file was re-packaged)
    /// can carry an href that no longer matches the reading order. Readium's
    /// `go(to:)` returns false for those before moving at all, so the jump looked
    /// dead no matter where the reader was. Repair by filename and write it back.
    private func resolveJumpLocator(
        _ locator: Locator,
        in pub: Publication,
        for annotationID: String,
        trace: inout AnnotationJumpTrace
    ) -> Locator? {
        if pub.readingOrder.firstIndexWithHREF(locator.href) != nil {
            trace.href(locator.href.string, resolvedTo: locator.href.string)
            return locator
        }
        func filename(_ path: String) -> String? {
            path.split(separator: "#").first?
                .split(separator: "/").last
                .map { $0.lowercased() }
        }
        guard let wanted = filename(locator.href.string),
              let match = pub.readingOrder.first(where: { filename($0.url().string) == wanted })
        else {
            trace.href(locator.href.string, resolvedTo: nil)
            return nil
        }
        trace.href(locator.href.string, resolvedTo: match.url().string)
        let repaired = locator.copy(href: match.url(), mediaType: match.mediaType)
        // Persist the repair so this annotation stops needing it.
        if let index = epubAnnotations.firstIndex(where: { $0.id == annotationID }),
           let newJSON = try? repaired.jsonString() {
            epubAnnotations[index].locatorJSON = newJSON
            epubAnnotations[index].updatedAt = Date()
            persistAnnotations(reloadContents: false)
        }
        return repaired
    }

    /// Where a painted range sits, or why it could not be located.
    struct AnnotationMeasure {
        var progression: Double = 0
        var visible = false
        /// Derived from the character offset because WebKit gave no geometry.
        var approx = false
        /// Page the highlight sits on, and the page currently on screen.
        var page: Int?
        var currentPage: Int?
        var pages: Int?
        var error: String?
        var isResolved: Bool { error == nil }
    }

    /// Asks the painted range where it sits, as a progression inside its resource.
    private func measureAnnotationInPage(id: String) async -> AnnotationMeasure {
        guard let nav = epubNavigator else { return AnnotationMeasure(error: "no navigator") }
        let json = Self.jsStringLiteral(id)
        // `evaluateJavaScript` hands back a `Result`, not a throwing value. Reading
        // it with `try?` produced an `Optional<Result>` that could never cast to
        // String, so this measurement silently returned nil on every single call.
        let result = await nav.evaluateJavaScript("""
        (function(){
          try {
            if (!window.__connectsAnn) return JSON.stringify({ error: 'painter missing' });
            var m = window.__connectsAnn.measure(\(json));
            return JSON.stringify(m || { error: 'unresolved' });
          } catch (e) { return JSON.stringify({ error: String(e) }); }
        })();
        """)
        guard let string = (try? result.get()) as? String,
              let data = string.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return AnnotationMeasure(error: "javascript failed") }
        guard let progression = obj["progression"] as? Double else {
            return AnnotationMeasure(error: (obj["error"] as? String) ?? "no progression")
        }
        return AnnotationMeasure(
            progression: progression,
            visible: (obj["visible"] as? Bool) ?? false,
            approx: (obj["approx"] as? Bool) ?? false,
            page: obj["page"] as? Int,
            currentPage: obj["currentPage"] as? Int,
            pages: obj["pages"] as? Int
        )
    }

    /// Puts the highlight's page on screen without asking the navigator to
    /// re-derive it from a progression. Used once the navigator has already
    /// brought the right resource in but keeps stopping on the wrong page.
    private func scrollAnnotationIntoView(id: String) async -> String {
        guard let nav = epubNavigator else { return "no navigator" }
        let json = Self.jsStringLiteral(id)
        let result = await nav.evaluateJavaScript("""
        (function(){
          try {
            if (!window.__connectsAnn || !window.__connectsAnn.scrollToPage) {
              return JSON.stringify({ error: 'painter missing' });
            }
            return JSON.stringify(window.__connectsAnn.scrollToPage(\(json)));
          } catch (e) { return JSON.stringify({ error: String(e) }); }
        })();
        """)
        guard let string = (try? result.get()) as? String else { return "javascript failed" }
        return string
    }

    /// Rewrites an annotation's stored locator with a real progression. Old
    /// highlights were all saved at 0, which is why jumping landed at the top of
    /// the chapter and then had to hunt from there.
    @discardableResult
    private func applyProgression(_ progression: Double, to id: String) -> Bool {
        guard let index = epubAnnotations.firstIndex(where: { $0.id == id }),
              let json = epubAnnotations[index].locatorJSON,
              let locator = try? Locator(jsonString: json)
        else { return false }
        let existing = locator.locations.progression ?? 0
        guard abs(existing - progression) > 0.0005 else { return false }
        guard let newJSON = try? locator.copy(locations: { $0.progression = progression }).jsonString()
        else { return false }
        epubAnnotations[index].locatorJSON = newJSON
        epubAnnotations[index].updatedAt = Date()
        return true
    }

    private func persistProgression(_ progression: Double, for id: String) {
        if applyProgression(progression, to: id) { persistAnnotations(reloadContents: false) }
    }

    /// Resolves TOC links for books like 新教伦理 (large spine files + #fragments).
    /// Retries while the navigator is busy jumping/loading so taps are not dropped.
    @MainActor
    private func jumpToTOCLink(_ link: Link, generation: UInt) async -> Bool {
        await restorePageWindowAfterPinch()
        guard generation == tocJumpGeneration else { return false }

        let options = NavigatorGoOptions(animated: false)
        guard let pub = publication else { return false }

        let locator = await pub.locate(link) ?? Self.locatorForTOCLink(link, in: pub)
        guard let locator else { return false }

        // Busy navigator (.jumping/.loading) used to reject go() → "no reaction".
        for _ in 0 ..< 50 {
            guard generation == tocJumpGeneration else { return false }
            if await epubNavigator?.go(to: locator, options: options) == true {
                await reinforceTOCFragment(link)
                return true
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        return false
    }

    private func reinforceTOCFragment(_ link: Link) async {
        guard let fragment = link.url().fragment, !fragment.isEmpty else { return }
        let escaped = fragment
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        // Column layout on large chapters finishes after go() returns — re-pin.
        for delayMs in [60, 180, 400] as [UInt64] {
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            let result = await epubNavigator?.evaluateJavaScript("""
            (function(){
              var id = '\(escaped)';
              var el = document.getElementById(id);
              if (!el) { try { el = document.querySelector('#' + CSS.escape(id)); } catch (e) {} }
              if (!el) return false;
              var pageW = window.innerWidth || document.documentElement.clientWidth || 1;
              function snap(offset){
                if (!isFinite(offset) || pageW < 1) return 0;
                var v = offset + 1;
                return v - (v % pageW);
              }
              var rects = el.getClientRects();
              var rect = (rects && rects.length) ? rects[0] : el.getBoundingClientRect();
              document.scrollingElement.scrollTo({
                left: snap(rect.left + window.scrollX),
                behavior: 'instant'
              });
              var after = el.getBoundingClientRect();
              return after.left < pageW * 0.95 && after.right > -pageW * 0.05;
            })();
            """)
            if case let .success(value)? = result, (value as? Bool) == true {
                return
            }
        }
    }

    /// Build a spine-bound locator when Readium's default locate returns nil.
    private static func locatorForTOCLink(_ link: Link, in pub: Publication) -> Locator? {
        let url = link.url()
        let fragment = url.fragment
        let bare = url.removingFragment().removingQuery()

        guard let spine = readingOrderLink(matching: bare, in: pub)
            ?? pub.linkWithHREF(bare).flatMap({ readingOrderLink(matching: $0.url(), in: pub) })
        else { return nil }

        return Locator(
            href: spine.url().removingFragment(),
            mediaType: spine.mediaType ?? .xhtml,
            title: link.title ?? spine.title,
            locations: Locator.Locations(
                fragments: fragment.map { [$0] } ?? [],
                progression: fragment == nil ? 0.0 : nil
            )
        )
    }

    private static func readingOrderLink(matching href: AnyURL, in pub: Publication) -> Link? {
        let bare = href.removingFragment().removingQuery()
        if let idx = pub.readingOrder.firstIndexWithHREF(bare) {
            return pub.readingOrder[idx]
        }
        let target = bare.normalized.string
        let targetPath = bare.path
        let base = (targetPath as NSString).lastPathComponent
        return pub.readingOrder.first { link in
            let u = link.url().removingFragment().removingQuery()
            let s = u.normalized.string
            if s == target { return true }
            if !targetPath.isEmpty, s.hasSuffix(targetPath) || target.hasSuffix(u.path) { return true }
            let linkBase = (u.path as NSString).lastPathComponent
            return !base.isEmpty && linkBase == base
        }
    }
}

private final class ConnectsHighlightPickerOverlay: UIView, ConnectsHighlightPickerHitMarker {}

/// Avoids retain cycle: WKUserContentController keeps script handlers strongly.
private final class FontPinchScriptProxy: NSObject, WKScriptMessageHandler {
    weak var owner: EbookReaderViewController?

    init(owner: EbookReaderViewController) {
        self.owner = owner
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "connectsFontPinch" else { return }
        owner?.handleInPageFontPinchMessage(message.body)
    }
}

private final class HighlightScriptProxy: NSObject, WKScriptMessageHandler {
    weak var owner: EbookReaderViewController?

    init(owner: EbookReaderViewController) {
        self.owner = owner
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "connectsHighlight" else { return }
        owner?.handleConnectsHighlightMessage(message.body)
    }
}
