import UIKit
import WebKit

/// Persists rich-message heights + JPEG snapshots across launches (cold-open paint).
enum RenderCacheStore {
    private static let heightsKey = "connects_web_heights_v1"
    private static let snapDirName = "connects_web_snaps"
    /// Body snapshots for many conversations × widths — keep a generous LRU.
    private static let maxSnapFiles = 160
    private static var saveHeightsWork: DispatchWorkItem?

    // MARK: - Heights

    static func loadHeights() -> [String: [String: CGFloat]] {
        guard let raw = UserDefaults.standard.dictionary(forKey: heightsKey) as? [String: [String: Double]] else {
            return [:]
        }
        var out: [String: [String: CGFloat]] = [:]
        for (cid, map) in raw {
            var inner: [String: CGFloat] = [:]
            for (mid, h) in map where h > 40 && h < 8000 {
                inner[mid] = CGFloat(h)
            }
            if !inner.isEmpty { out[cid] = inner }
        }
        return out
    }

    static func saveHeights(_ cache: [String: [String: CGFloat]],
                            messageOrder: [String: [String]] = [:],
                            debounce: TimeInterval = 0.6) {
        saveHeightsWork?.cancel()
        let work = DispatchWorkItem {
            var raw: [String: [String: Double]] = [:]
            for (cid, map) in cache {
                var inner: [String: Double] = [:]
                if let order = messageOrder[cid], !order.isEmpty {
                    // Keep the tail of long threads — readers open at the latest turn.
                    for mid in order.suffix(240) {
                        guard let h = map[mid], h > 40 && h < 8000 else { continue }
                        inner[mid] = Double(h)
                    }
                } else {
                    for (mid, h) in map where h > 40 && h < 8000 {
                        inner[mid] = Double(h)
                        if inner.count >= 200 { break }
                    }
                }
                if !inner.isEmpty { raw[cid] = inner }
            }
            // Cap conversations.
            if raw.count > 40 {
                let keys = Array(raw.keys.prefix(40))
                raw = Dictionary(uniqueKeysWithValues: keys.map { ($0, raw[$0]!) })
            }
            UserDefaults.standard.set(raw, forKey: heightsKey)
        }
        saveHeightsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    static func clearHeights() {
        saveHeightsWork?.cancel()
        UserDefaults.standard.removeObject(forKey: heightsKey)
    }

    // MARK: - Snapshots

    static func snapshotExists(forKey key: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(forKey: key).path)
    }

    static func snapshot(forKey key: String) -> UIImage? {
        let url = fileURL(forKey: key)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let raw = UIImage(data: data),
              let cg = raw.cgImage else { return nil }
        // jpegData drops UIImage.scale. Prefer screen scale (retina captures); if the
        // bitmap's pixel width is already ~point-sized (older scale-1 snaps), keep scale 1.
        let screen = UIScreen.main.scale
        let px = CGFloat(cg.width)
        let scale: CGFloat
        if screen > 1, px > 120, px / screen >= 120 {
            scale = screen
        } else {
            scale = 1
        }
        let image = UIImage(cgImage: cg, scale: scale, orientation: .up)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
        return image
    }

    static func storeSnapshot(_ image: UIImage, forKey key: String) {
        // Encode off-main but at userInitiated so cold-kill shortly after open still persists.
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = image.jpegData(compressionQuality: 0.78) else { return }
            let dir = snapDirectory()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = fileURL(forKey: key)
            try? data.write(to: url, options: .atomic)
            pruneSnapshotsIfNeeded()
        }
    }

    static func clearSnapshots() {
        let dir = snapDirectory()
        try? FileManager.default.removeItem(at: dir)
    }

    static func clearAll() {
        clearHeights()
        clearSnapshots()
    }

    /// Stable fingerprint — Swift's `hashValue` is not stable across launches.
    static func stamp(_ text: String) -> String {
        var h: UInt64 = 5381
        for b in text.utf8 {
            h = ((h << 5) &+ h) &+ UInt64(b)
        }
        return "\(text.count)-\(String(h, radix: 16))"
    }

    private static func snapDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent(snapDirName, isDirectory: true)
    }

    private static func fileURL(forKey key: String) -> URL {
        let name = stamp(key) + ".jpg"
        return snapDirectory().appendingPathComponent(name)
    }

    private static func pruneSnapshotsIfNeeded() {
        let dir = snapDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        guard files.count > maxSnapFiles else { return }
        let sorted = files.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
        for url in sorted.prefix(files.count - maxSnapFiles) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - Stable finished-reply renderer

/// Immutable raster output for a completed rich reply. UITableView cells only
/// display these tiles; they never host or remeasure a WKWebView while scrolling.
struct StableRenderedReply {
    let height: CGFloat
    let width: CGFloat
    let tiles: [UIImage]
    let tileHeights: [CGFloat]
}

private final class StableRenderedReplyBox: NSObject {
    let value: StableRenderedReply
    init(_ value: StableRenderedReply) { self.value = value }
}

private struct StableRenderedReplyMeta: Codable {
    let height: Double
    let tileHeights: [Double]
}

/// A single, serialized offscreen KaTeX worker. Keeping WebKit out of recycled
/// table cells removes the render → remeasure → relayout feedback loop.
final class StableRichRenderer: NSObject, WKNavigationDelegate {
    static let shared = StableRichRenderer()

    enum Priority {
        case visible
        case prefetch
        case layoutWarmup
    }

    private struct Job {
        let key: String
        let markdown: String
        let width: CGFloat
        let font: CGFloat
        let colors: ThemeColors
        let needsMath: Bool
    }

    private static let metaKey = "connects_stable_rich_meta_v1"
    private static let tileHeight: CGFloat = 1024
    // Keep the recent scrolling neighbourhood decoded. Falling back to plain
    // text while a disk image decodes is itself a visible flash.
    private static let maxMemoryCost = 88 * 1024 * 1024
    private let memory = NSCache<NSString, StableRenderedReplyBox>()
    /// One nearest-width preview per reply signature. It prevents a cell from
    /// falling back to UILabel while the exact layout tile is decoded/rendered.
    private let previewMemory = NSCache<NSString, StableRenderedReplyBox>()
    private var waiters: [String: [(StableRenderedReply?) -> Void]] = [:]
    private var previewWaiters: [String: [(StableRenderedReply?) -> Void]] = [:]
    private var queue: [Job] = []
    private var active: Job?
    private var webView: WKWebView?
    private var host: UIView?
    private var tileIndex = 0
    private var renderedHeight: CGFloat = 0
    private var renderedTiles: [UIImage] = []
    private var renderedTileHeights: [CGFloat] = []

    private override init() {
        super.init()
        memory.totalCostLimit = Self.maxMemoryCost
        memory.countLimit = 36
    }

    static func key(messageID: String, content: String, font: CGFloat, appearance: String, width: CGFloat) -> String {
        "\(baseKey(messageID: messageID, content: content, font: font, appearance: appearance))|w\(Int(width.rounded()))"
    }

    static func baseKey(messageID: String, content: String, font: CGFloat, appearance: String) -> String {
        "\(messageID)|\(RenderCacheStore.stamp(content))|\(Int(font))|\(appearance)"
    }

    /// iPad Air content widths for portrait/landscape × sidebar/no-sidebar.
    /// Portrait and landscape without a sidebar both cap at 680pt, so that
    /// image is intentionally shared rather than rendered twice.
    static func layoutProfileWidths(primary: CGFloat) -> [CGFloat] {
        let profiles: [CGFloat] = [400, 656, 680, primary.rounded()]
        return Array(Set(profiles.map { min(max($0, 280), DSTheme.bubbleMaxWidth) })).sorted()
    }

    /// The only synchronous path used from `cellForRowAt`. It never touches
    /// disk or WebKit, so a cache hit binds its finished raster in one frame.
    func artifact(forKey key: String) -> StableRenderedReply? {
        memory.object(forKey: key as NSString)?.value
    }

    /// A decoded artifact from any layout width for the same immutable reply.
    /// Cells may scale it temporarily while the exact-width tiles load, avoiding
    /// a visible placeholder on cache eviction or width changes.
    func previewArtifact(forBaseKey baseKey: String) -> StableRenderedReply? {
        previewMemory.object(forKey: baseKey as NSString)?.value
    }

    /// Fixed reply height available before image decoding. This lets a cell use
    /// the final row geometry for a disk-cached artifact without a table pass.
    func metadataHeight(forKey key: String) -> CGFloat? {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.metaKey) as? [String: [String: Any]],
              let height = raw[key]?["height"] as? Double,
              height > 1 else { return nil }
        return CGFloat(height)
    }

    func request(key: String,
                 markdown: String,
                 width: CGFloat,
                 font: CGFloat,
                 colors: ThemeColors,
                 priority: Priority = .prefetch,
                 completion: @escaping (StableRenderedReply?) -> Void) {
        if let box = memory.object(forKey: key as NSString) {
            completion(box.value)
            return
        }
        if waiters[key] != nil {
            waiters[key]?.append(completion)
            return
        }
        waiters[key] = [completion]
        loadFromDisk(key: key) { [weak self] artifact in
            guard let self = self else { return }
            if let artifact = artifact {
                self.cache(artifact, for: key)
                self.finish(key: key, artifact: artifact)
                return
            }
            let normalized = MarkdownHTMLRenderer.normalizeForRender(markdown)
            let job = Job(
                key: key,
                markdown: normalized,
                width: max(width, 240),
                font: font,
                colors: colors,
                needsMath: MathContentDetector.containsMath(normalized)
            )
            switch priority {
            case .visible:
                self.queue.insert(job, at: 0)
            case .prefetch, .layoutWarmup:
                self.queue.append(job)
            }
            self.startNextIfNeeded()
        }
    }

    func clearAll() {
        memory.removeAllObjects()
        previewMemory.removeAllObjects()
        UserDefaults.standard.removeObject(forKey: Self.metaKey)
        try? FileManager.default.removeItem(at: tileDirectory())
    }

    /// Drop stale prefetch jobs when the reader switches conversations.
    func cancelPendingJobs() {
        queue.removeAll()
    }

    private func startNextIfNeeded() {
        guard active == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        active = job
        ensureWebView()
        let html = MarkdownHTMLRenderer.shellHTML(
            textColor: job.colors.textPrimary,
            backgroundColor: job.colors.background,
            secondaryColor: job.colors.textSecondary,
            fontSize: job.font,
            includeMath: job.needsMath
        )
        host?.frame.size = CGSize(width: job.width, height: 1)
        webView?.frame = CGRect(x: 0, y: 0, width: job.width, height: 2)
        webView?.loadHTMLString(html, baseURL: MarkdownHTMLRenderer.resourceBaseURL)
    }

    private func ensureWebView() {
        guard webView == nil else { return }
        let config = WKWebViewConfiguration()
        config.processPool = WebKitRenderWarmup.processPool
        config.preferences.javaScriptEnabled = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInset = .zero
        // WebKit does not reliably paint/snapshot a clipped 2pt descendant on
        // iOS 12. Keep a real-sized, almost transparent renderer in-window.
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        host.alpha = 0.01
        host.clipsToBounds = false
        let window = UIApplication.shared.keyWindow
            ?? UIApplication.shared.windows.first(where: { $0.isKeyWindow })
            ?? UIApplication.shared.windows.first
        window?.addSubview(host)
        host.addSubview(view)
        self.host = host
        self.webView = view
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let job = active else { return }
        let check = job.needsMath
            ? "(typeof marked!=='undefined'&&typeof katex!=='undefined')?1:0"
            : "(typeof marked!=='undefined')?1:0"
        webView.evaluateJavaScript(check) { [weak self] result, _ in
            guard let self = self, let active = self.active, active.key == job.key else { return }
            guard (result as? NSNumber)?.intValue == 1 else {
                self.completeActive(nil)
                return
            }
            webView.evaluateJavaScript(MarkdownHTMLRenderer.renderJavaScript(content: active.markdown)) { [weak self] result, _ in
                guard let self = self, self.active?.key == active.key else { return }
                let raw: CGFloat
                if let number = result as? NSNumber {
                    raw = CGFloat(number.doubleValue)
                } else {
                    raw = 0
                }
                guard raw > 1 else {
                    self.completeActive(nil)
                    return
                }
                // KaTeX schedules its final font/layout pass after returning.
                // Capture after that pass, never while a visible cell scrolls.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self, weak webView] in
                    guard let self = self,
                          let webView = webView,
                          self.active?.key == active.key else { return }
                    webView.evaluateJavaScript(MarkdownHTMLRenderer.measureJavaScript()) { [weak self] result, _ in
                        guard let self = self, self.active?.key == active.key else { return }
                        let finalHeight = (result as? NSNumber).map { CGFloat($0.doubleValue) } ?? raw
                        self.beginTileCapture(height: finalHeight, width: active.width)
                    }
                }
            }
        }
    }

    private func beginTileCapture(height: CGFloat, width: CGFloat) {
        renderedHeight = min(max(height, 20), 30_000)
        webView?.frame.size = CGSize(width: width, height: renderedHeight)
        webView?.setNeedsLayout()
        webView?.layoutIfNeeded()
        tileIndex = 0
        renderedTiles.removeAll()
        renderedTileHeights.removeAll()
        captureNextTile()
    }

    private func captureNextTile() {
        guard let job = active, let webView = webView else { return }
        let y = CGFloat(tileIndex) * Self.tileHeight
        guard y < renderedHeight else {
            let artifact = StableRenderedReply(
                height: renderedHeight,
                width: webView.bounds.width,
                tiles: renderedTiles,
                tileHeights: renderedTileHeights
            )
            storeToDisk(artifact, key: job.key)
            cache(artifact, for: job.key)
            completeActive(artifact)
            return
        }
        let h = min(Self.tileHeight, renderedHeight - y)
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: y, width: webView.bounds.width, height: h)
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            guard let self = self, self.active?.key == job.key else { return }
            guard let image = image else {
                self.completeActive(nil)
                return
            }
            self.renderedTiles.append(image)
            self.renderedTileHeights.append(h)
            self.tileIndex += 1
            self.captureNextTile()
        }
    }

    private func completeActive(_ artifact: StableRenderedReply?) {
        guard let key = active?.key else { return }
        active = nil
        finish(key: key, artifact: artifact)
        startNextIfNeeded()
    }

    private func finish(key: String, artifact: StableRenderedReply?) {
        let callbacks = waiters.removeValue(forKey: key) ?? []
        callbacks.forEach { $0(artifact) }
    }

    private func cache(_ artifact: StableRenderedReply, for key: String) {
        let cost = artifact.tiles.reduce(0) {
            $0 + Int($1.size.width * $1.scale * $1.size.height * $1.scale * 4)
        }
        memory.setObject(StableRenderedReplyBox(artifact), forKey: key as NSString, cost: cost)
        previewMemory.setObject(StableRenderedReplyBox(artifact), forKey: base(from: key) as NSString)
    }

    /// Supplies a stable nearest-width artifact while the exact profile is
    /// loading. It is deliberately non-blocking and never initiates WebKit.
    func requestPreview(baseKey: String,
                        targetWidth: CGFloat,
                        completion: @escaping (StableRenderedReply?) -> Void) {
        if let box = previewMemory.object(forKey: baseKey as NSString) {
            completion(box.value)
            return
        }
        let requestKey = "\(baseKey)|target\(Int(targetWidth.rounded()))"
        if previewWaiters[requestKey] != nil {
            previewWaiters[requestKey]?.append(completion)
            return
        }
        previewWaiters[requestKey] = [completion]
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.metaKey) as? [String: [String: Any]] else {
            finishPreview(requestKey: requestKey, artifact: nil)
            return
        }
        let candidate = raw.keys
            .filter { $0.hasPrefix(baseKey + "|w") }
            .min { lhs, rhs in
                let l = CGFloat((raw[lhs]?["width"] as? Double) ?? 0)
                let r = CGFloat((raw[rhs]?["width"] as? Double) ?? 0)
                return abs(l - targetWidth) < abs(r - targetWidth)
            }
        guard let key = candidate else {
            finishPreview(requestKey: requestKey, artifact: nil)
            return
        }
        loadFromDisk(key: key) { [weak self] artifact in
            if let artifact = artifact {
                self?.cache(artifact, for: key)
            }
            self?.finishPreview(requestKey: requestKey, artifact: artifact)
        }
    }

    private func finishPreview(requestKey: String, artifact: StableRenderedReply?) {
        let callbacks = previewWaiters.removeValue(forKey: requestKey) ?? []
        callbacks.forEach { $0(artifact) }
    }

    private func tileDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("connects_stable_rich", isDirectory: true)
    }

    private func stem(_ key: String) -> String { RenderCacheStore.stamp(key) }

    private func base(from key: String) -> String {
        guard let range = key.range(of: "|w", options: .backwards) else { return key }
        return String(key[..<range.lowerBound])
    }

    private func loadFromDisk(key: String, completion: @escaping (StableRenderedReply?) -> Void) {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.metaKey) as? [String: [String: Any]],
              let item = raw[key],
              let height = item["height"] as? Double,
              let width = item["width"] as? Double,
              let heights = item["tileHeights"] as? [Double] else {
            completion(nil)
            return
        }
        let directory = tileDirectory()
        let name = stem(key)
        let values: [CGFloat] = heights.map { CGFloat($0) }
        DispatchQueue.global(qos: .userInitiated).async {
            var images = [UIImage]()
            var complete = true
            for index in values.indices {
                let url = directory.appendingPathComponent("\(name)-\(index).jpg")
                if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                    images.append(image)
                } else {
                    complete = false
                    break
                }
            }
            let artifact: StableRenderedReply?
            if complete {
                artifact = StableRenderedReply(
                    height: CGFloat(height),
                    width: CGFloat(width),
                    tiles: images,
                    tileHeights: values
                )
            } else {
                artifact = nil
            }
            DispatchQueue.main.async {
                completion(artifact)
            }
        }
    }

    private func storeToDisk(_ artifact: StableRenderedReply, key: String) {
        let height = Double(artifact.height)
        let width = Double(artifact.width)
        let tileHeights = artifact.tileHeights.map(Double.init)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let dir = self.tileDirectory()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (index, image) in artifact.tiles.enumerated() {
                let url = dir.appendingPathComponent("\(self.stem(key))-\(index).jpg")
                try? image.jpegData(compressionQuality: 0.82)?.write(to: url, options: .atomic)
            }
            DispatchQueue.main.async {
                var raw = UserDefaults.standard.dictionary(forKey: Self.metaKey) as? [String: [String: Any]] ?? [:]
                raw[key] = ["height": height, "width": width, "tileHeights": tileHeights]
                if raw.count > 80 {
                    raw = Dictionary(uniqueKeysWithValues: raw.prefix(80).map { ($0.key, $0.value) })
                }
                UserDefaults.standard.set(raw, forKey: Self.metaKey)
            }
        }
    }
}
