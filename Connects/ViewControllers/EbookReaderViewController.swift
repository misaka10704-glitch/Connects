import UIKit
import ReadiumShared
import ReadiumNavigator

/// Study ebook shell: EPUB via Readium navigator. MOBI/AZW deferred.
final class EbookReaderViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, EPUBNavigatorDelegate {
    private let topBar = UIView()
    private let topBarSeparator = UIView()
    private let sidebarButton = UIButton(type: .system)
    private let contentsButton = UIButton(type: .system)
    private let fontSmallerButton = UIButton(type: .system)
    private let fontLargerButton = UIButton(type: .system)
    private let fileTitleButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let contentHost = UIView()
    private let contentsPanelHost = UIView()
    private let contentsDim = UIControl()
    private let contentsTable = UITableView(frame: .zero, style: .plain)

    private var sidebarButtonWidthConstraint: NSLayoutConstraint!
    private var contentsPanelWidth: NSLayoutConstraint!
    private var contentsPanelTrailing: NSLayoutConstraint!
    private var isContentsPanelVisible = false
    private let contentsPanelWidthConstant: CGFloat = 240

    private var currentDocumentID: String?
    private var documentDisplayTitle = ""
    private var loadGeneration: UInt = 0
    private var engineKind: EngineKind = .none
    private var readerSurfaceActive = true
    private var progressWorkItem: DispatchWorkItem?

    // EPUB
    private var publication: Publication?
    private var epubNavigator: EPUBNavigatorViewController?
    private var lastLocatorJSON: String?
    private var tocLinks: [Link] = []
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
            self, selector: #selector(themeChanged), name: .themeDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(fontSizeSettingChanged), name: .ebookReaderFontSizeDidChange, object: nil
        )
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
        sidebarButtonWidthConstraint = sidebarButton.widthAnchor.constraint(equalToConstant: 40)

        contentsButton.translatesAutoresizingMaskIntoConstraints = false
        contentsButton.setImage(ActionIconFactory.image(.toc, pointSize: 18), for: .normal)
        contentsButton.tintColor = DSTheme.c.textSecondary
        contentsButton.accessibilityLabel = "目录"
        contentsButton.addTarget(self, action: #selector(contentsTapped), for: .touchUpInside)
        topBar.addSubview(contentsButton)

        fontSmallerButton.translatesAutoresizingMaskIntoConstraints = false
        fontSmallerButton.setTitle("A−", for: .normal)
        fontSmallerButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        fontSmallerButton.setTitleColor(DSTheme.c.textSecondary, for: .normal)
        fontSmallerButton.addTarget(self, action: #selector(fontSmallerTapped), for: .touchUpInside)
        topBar.addSubview(fontSmallerButton)

        fontLargerButton.translatesAutoresizingMaskIntoConstraints = false
        fontLargerButton.setTitle("A+", for: .normal)
        fontLargerButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        fontLargerButton.setTitleColor(DSTheme.c.textSecondary, for: .normal)
        fontLargerButton.addTarget(self, action: #selector(fontLargerTapped), for: .touchUpInside)
        topBar.addSubview(fontLargerButton)

        fileTitleButton.translatesAutoresizingMaskIntoConstraints = false
        fileTitleButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        fileTitleButton.titleLabel?.lineBreakMode = .byTruncatingMiddle
        fileTitleButton.setTitleColor(DSTheme.c.textPrimary, for: .normal)
        fileTitleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fileTitleButton.addTarget(self, action: #selector(fileTitleTapped), for: .touchUpInside)
        topBar.addSubview(fileTitleButton)

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.backgroundColor = DSTheme.c.background
        view.addSubview(contentHost)

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

        contentsTable.translatesAutoresizingMaskIntoConstraints = false
        contentsTable.dataSource = self
        contentsTable.delegate = self
        contentsTable.allowsSelection = true
        contentsTable.register(UITableViewCell.self, forCellReuseIdentifier: "ch")
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
            topBar.heightAnchor.constraint(equalToConstant: 40),

            topBarSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBarSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBarSeparator.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            topBarSeparator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            sidebarButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 4),
            sidebarButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            sidebarButtonWidthConstraint,
            sidebarButton.heightAnchor.constraint(equalToConstant: 40),

            fileTitleButton.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            fileTitleButton.topAnchor.constraint(equalTo: topBar.topAnchor),
            fileTitleButton.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            fileTitleButton.leadingAnchor.constraint(greaterThanOrEqualTo: sidebarButton.trailingAnchor, constant: 4),
            fileTitleButton.trailingAnchor.constraint(lessThanOrEqualTo: fontSmallerButton.leadingAnchor, constant: -4),

            contentsButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -4),
            contentsButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            contentsButton.widthAnchor.constraint(equalToConstant: 40),
            contentsButton.heightAnchor.constraint(equalToConstant: 40),

            fontLargerButton.trailingAnchor.constraint(equalTo: contentsButton.leadingAnchor, constant: -2),
            fontLargerButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            fontLargerButton.widthAnchor.constraint(equalToConstant: 36),
            fontLargerButton.heightAnchor.constraint(equalToConstant: 40),

            fontSmallerButton.trailingAnchor.constraint(equalTo: fontLargerButton.leadingAnchor),
            fontSmallerButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            fontSmallerButton.widthAnchor.constraint(equalToConstant: 36),
            fontSmallerButton.heightAnchor.constraint(equalToConstant: 40),

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

            contentsTable.leadingAnchor.constraint(equalTo: contentsPanelHost.leadingAnchor),
            contentsTable.trailingAnchor.constraint(equalTo: contentsPanelHost.trailingAnchor),
            contentsTable.topAnchor.constraint(equalTo: contentsPanelHost.topAnchor),
            contentsTable.bottomAnchor.constraint(equalTo: contentsPanelHost.bottomAnchor),
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
    func setSidebarButtonHidden(_ hidden: Bool) {
        sidebarButton.isHidden = hidden
        sidebarButtonWidthConstraint.constant = hidden ? 0 : 40
    }
    func updateSidebarToggle(collapsed: Bool) {
        let kind: ActionIconFactory.Kind = collapsed ? .sidebar : .sidebarOpen
        sidebarButton.setImage(ActionIconFactory.image(kind, pointSize: 18), for: .normal)
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
    func pauseReading() { saveReadingProgressNow() }

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
                    SettingsManager.shared.ebookReaderFontSize = scale
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
            // Corrupt Foliate / foreign locator often leaves Readium spinning forever.
            try await openEPUBOnce(url: url, restoreJSON: nil)
            if let id = currentDocumentID {
                StudyProgressStore.shared.clearEbookLocator(for: id)
            }
        }
    }

    @MainActor
    private func openEPUBOnce(url: URL, restoreJSON: String?) async throws {
        teardownEngines()
        engineKind = .epub
        didKickEPUBLayout = false
        sawEPUBLocationEvent = false

        let pub = try await ReadiumEbookOpener.openEPUB(at: url)
        guard !pub.readingOrder.isEmpty else {
            throw ReadiumEbookError.openFailed("EPUB 阅读顺序为空")
        }
        publication = pub

        await waitForReadableContentHostSize()

        let initial = validatedRestoreLocator(restoreJSON, in: pub)

        // Arm before embedding — first locationDidChange can fire during initialize().
        waitingForFirstEPUBLocation = true

        var config = EPUBNavigatorViewController.Configuration()
        config.preferences = makeEPUBPreferences()
        config.defaults = EPUBDefaults(pageMargins: 0.85, scroll: false, spread: .never)
        // Study top bar already provides chrome — hug it at the top.
        // Bottom must clear the floating ▲▼ stage chip on both iPhone and iPad.
        let insets = Self.readingContentInsets
        config.contentInset = [
            .compact: insets,
            .regular: insets,
        ]
        let rs = readingSystemCSSColors()
        // Wide enough for iPad, but keep a readable side gutter (not edge-to-edge).
        config.readiumCSSRSProperties = CSSRSProperties(
            pageGutter: CSSPxLength(22),
            maxLineLength: CSSRemLength(100),
            textColor: rs.text,
            backgroundColor: rs.background
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

        addChild(nav)
        // Match AI chat surface — not pure white / pure black Readium defaults.
        let pageBG = DSTheme.c.background
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

        // Let EPUBNavigator.initialize() finish, then push a real size + navigation.
        try? await Task.sleep(nanoseconds: 250_000_000)
        if contentHost.bounds.width > 32 {
            nav.view.frame = contentHost.bounds
        }
        nav.view.setNeedsLayout()
        nav.view.layoutIfNeeded()
        // Triggers viewWillAppear → viewSizeWillChange (needed when embedded in Study).
        nav.beginAppearanceTransition(true, animated: false)
        nav.endAppearanceTransition()

        if let initial {
            _ = await nav.go(to: initial)
        } else if let first = pub.readingOrder.first {
            _ = await nav.go(to: first)
        }

        // Soft wait only — never tear down a successfully opened navigator.
        _ = await waitForEPUBPainted(timeoutNanoseconds: 2_500_000_000)
        waitingForFirstEPUBLocation = false
        firstEPUBLocationContinuation = nil
        applyEPUBPreferences()
        applyReadingSurfaceColors()
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
            if let nav = epubNavigator, nav.view.bounds.width > 32, inkRatio(of: nav.view) > 0.02 {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if sawEPUBLocationEvent { return true }
        if let nav = epubNavigator, nav.view.bounds.width > 32, inkRatio(of: nav.view) > 0.02 {
            return true
        }
        return false
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
        tocLinks = []
        epubPositionCount = 0
        engineKind = .none
        contentsTable.reloadData()
    }

    private func makeEPUBPreferences() -> EPUBPreferences {
        let scale = Double(SettingsManager.shared.ebookReaderFontSize / 18.0)
        let isDark = ThemeManager.shared.mode == .dark
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
            fontSize: max(0.7, min(2.0, scale)),
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

    private func applyEPUBPreferences() {
        epubNavigator?.submitPreferences(makeEPUBPreferences())
        applyReadingSurfaceColors()
    }

    /// Shell + navigator chrome use the same tokens as ChatViewController.
    private func applyReadingSurfaceColors() {
        let bg = DSTheme.c.background
        view.backgroundColor = bg
        topBar.backgroundColor = bg
        contentHost.backgroundColor = bg
        epubNavigator?.view.backgroundColor = bg
        contentsPanelHost.backgroundColor = DSTheme.c.surface
        contentsTable.backgroundColor = DSTheme.c.surface
        topBarSeparator.backgroundColor = DSTheme.c.border.withAlphaComponent(0.55)
    }

    private func readingSystemCSSColors() -> (text: CSSColor, background: CSSColor) {
        let isDark = ThemeManager.shared.mode == .dark
        if isDark {
            return (CSSHexColor("#ECECF1"), CSSHexColor("#212121"))
        }
        return (CSSHexColor("#0D0D0D"), CSSHexColor("#FFFFFF"))
    }

    private func restoreLocator(json: String) {
        guard engineKind == .epub,
              let locator = try? Locator(jsonString: json) else { return }
        Task { await epubNavigator?.go(to: locator) }
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
        let page = currentPageLabel()
        let title = page.isEmpty ? "\(file) ▾" : "\(file) ▾ · \(page)"
        fileTitleButton.setTitle(title, for: .normal)
        fileTitleButton.setTitleColor(DSTheme.c.textPrimary, for: .normal)
        fontSmallerButton.setTitleColor(DSTheme.c.textSecondary, for: .normal)
        fontLargerButton.setTitleColor(DSTheme.c.textSecondary, for: .normal)
        contentsButton.tintColor = DSTheme.c.textSecondary
        sidebarButton.tintColor = DSTheme.c.textSecondary
        applyReadingSurfaceColors()
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

    @objc private func fontSmallerTapped() {
        SettingsManager.shared.ebookReaderFontSize -= 2
        applyEPUBPreferences()
    }

    @objc private func fontLargerTapped() {
        SettingsManager.shared.ebookReaderFontSize += 2
        applyEPUBPreferences()
    }

    @objc private func fontSizeSettingChanged() {
        applyEPUBPreferences()
    }

    @objc private func themeChanged() {
        refreshTitleChrome()
        applyEPUBPreferences()
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

    private func presentFootnotePopup(html: String, referrerHTML: String?) {
        _ = referrerHTML
        var body = Self.plainText(fromHTML: html)
        // Drop leading [n] marker — popup shows note body only.
        if let m = body.range(of: #"^\[\d+\]\s*"#, options: .regularExpression) {
            body = String(body[m.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !body.isEmpty else {
            ConnectsToast.show("未找到注释内容", in: view, duration: 1.2)
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
        backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.14)
        backdrop.addTarget(self, action: #selector(dismissFootnotePopupFast), for: .touchDown)

        let cardWidth: CGFloat = min(380, max(container.bounds.width - 48, 300))
        let cardHeight: CGFloat = min(320, max(container.bounds.height * 0.42, 260))

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = DSTheme.c.surface.withAlphaComponent(0.88)
        card.layer.cornerRadius = 16
        card.clipsToBounds = true
        card.isUserInteractionEnabled = true
        card.tag = 90421
        card.layer.borderWidth = 1 / UIScreen.main.scale
        card.layer.borderColor = DSTheme.c.border.withAlphaComponent(0.35).cgColor

        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.showsVerticalScrollIndicator = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.font = UIFont.systemFont(ofSize: 16)
        textView.textColor = DSTheme.c.textPrimary
        textView.text = body
        textView.dataDetectorTypes = []

        card.addSubview(textView)
        overlay.addSubview(backdrop)
        overlay.addSubview(card)
        container.addSubview(overlay)
        footnoteOverlay = overlay

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
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            overlay.alpha = 1
        }
    }

    @objc private func dismissFootnotePopupFast() {
        dismissFootnotePopup(animated: true)
    }

    @objc private func dismissFootnotePopup() {
        dismissFootnotePopup(animated: true)
    }

    private func dismissFootnotePopup(animated: Bool) {
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

    // MARK: - TOC table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard engineKind == .epub else { return 0 }
        return max(tocLinks.count, 1)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ch", for: indexPath)
        if engineKind == .epub, !tocLinks.isEmpty {
            let link = tocLinks[indexPath.row]
            cell.textLabel?.text = link.title ?? link.url().string
            cell.textLabel?.textColor = DSTheme.c.textPrimary
            cell.selectionStyle = .default
            cell.isUserInteractionEnabled = true
        } else if engineKind == .epub {
            cell.textLabel?.text = "暂无目录"
            cell.textLabel?.textColor = DSTheme.c.textSecondary
            cell.selectionStyle = .none
            cell.isUserInteractionEnabled = false
        } else {
            cell.textLabel?.text = nil
            cell.selectionStyle = .none
        }
        cell.textLabel?.numberOfLines = 2
        cell.textLabel?.font = UIFont.systemFont(ofSize: 14)
        cell.backgroundColor = DSTheme.c.surface
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard engineKind == .epub, tocLinks.indices.contains(indexPath.row) else { return }
        let link = tocLinks[indexPath.row]
        hideContentsPanel()
        Task { @MainActor in
            let ok = await epubNavigator?.go(to: link) ?? false
            if !ok {
                ConnectsToast.show("无法跳转到该章节", in: self.view, duration: 1.4)
            }
        }
    }
}
