import Foundation
import UIKit

enum MarkdownStudyImporterError: LocalizedError {
    case fileTooLarge
    case invalidMarkdown
    case noMarkdownInFolder
    case pathEscapesAccessRoot

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "Markdown 文件过大，无法导入。"
        case .invalidMarkdown:
            return "无法读取 Markdown 文件。"
        case .noMarkdownInFolder:
            return "该文件夹内没有找到 .md / .markdown 文件。"
        case .pathEscapesAccessRoot:
            return "图片路径超出已授权文件夹（例如用了 ../）。请改选更高一层的共同根目录。"
        }
    }
}

struct MarkdownStudyImportResult {
    /// Markdown with `![…](…)` rewritten to clickable `〔图〕` links (`https://connects.local/assets/…`).
    let markdown: String
    let fingerprint: String
    let displayTitle: String
    let missingImagePaths: [String]
    /// Relative paths like `assets/abc.png` → file bytes (persist beside original.md).
    let assets: [(relativePath: String, data: Data)]
}

/// Indexes Markdown under a security-scoped folder (shared `assets/` for many .md files).
enum MarkdownStudyImporter {
    /// Fake https host kept by marked.js; intercepted in the Study reader.
    static let assetURLHost = "connects.local"
    static let assetURLScheme = "https"
    private static let maxMarkdownBytes: Int64 = 8 * 1024 * 1024

    /// Unzip a markdown package and return the content root (single top-level folder if present).
    static func unzipPackage(zipURL: URL) throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("ConnectsMDZip-\(UUID().uuidString)", isDirectory: true)
        if fm.fileExists(atPath: staging.path) {
            try fm.removeItem(at: staging)
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let accessing = zipURL.startAccessingSecurityScopedResource()
        defer { if accessing { zipURL.stopAccessingSecurityScopedResource() } }
        try SimpleZip.unzip(archiveURL: zipURL, to: staging)

        let kids = (try? fm.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let dirs = kids.filter { ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) == true }
        let files = kids.filter { ((try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile) == true }
        // Common case: zip contains one root folder `lab_sys_review/`.
        if dirs.count == 1, files.isEmpty {
            return dirs[0]
        }
        return staging
    }

    /// List markdown files under a folder (shallow + one nested level). Caller must hold folder access.
    static func listMarkdownFiles(inFolder folderURL: URL) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let kids = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for url in kids {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true, isMarkdownFilename(url.lastPathComponent) {
                found.append(url)
                continue
            }
            if values?.isDirectory == true {
                // e.g. notes/*.md next to shared assets/ at folder root
                if let nested = try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles]
                ) {
                    for child in nested where (try? child.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                        && isMarkdownFilename(child.lastPathComponent) {
                        found.append(child)
                    }
                }
            }
        }
        return found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func isMarkdownFilename(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    /// - Parameters:
    ///   - markdownURL: the chosen .md
    ///   - accessRoot: best-effort sibling root (often fails on iCloud); extras fill the gap
    ///   - extraImageFiles: user-picked images from shared `assets/` (matched by filename)
    static func importSnapshot(markdownURL: URL,
                               accessRoot: URL,
                               extraImageFiles: [URL] = [],
                               title: String? = nil) throws -> MarkdownStudyImportResult {
        let rootAccess = accessRoot.startAccessingSecurityScopedResource()
        let fileAccess = markdownURL.startAccessingSecurityScopedResource()
        defer {
            if fileAccess { markdownURL.stopAccessingSecurityScopedResource() }
            if rootAccess { accessRoot.stopAccessingSecurityScopedResource() }
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: markdownURL.path)
        let size = attrs[.size] as? Int64 ?? 0
        guard size <= maxMarkdownBytes else { throw MarkdownStudyImporterError.fileTooLarge }

        guard let data = readFileData(markdownURL),
              let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw MarkdownStudyImporterError.invalidMarkdown
        }

        let displayTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? markdownURL.deletingPathExtension().lastPathComponent

        var extrasByBasename: [String: Data] = [:]
        for imgURL in extraImageFiles {
            let access = imgURL.startAccessingSecurityScopedResource()
            defer { if access { imgURL.stopAccessingSecurityScopedResource() } }
            guard let bytes = readFileData(imgURL), !bytes.isEmpty else { continue }
            extrasByBasename[imgURL.lastPathComponent.lowercased()] = bytes
        }

        let sourceDir = markdownURL.deletingLastPathComponent()
        let staged = try stage(
            text,
            sourceDirectory: sourceDir,
            accessRoot: accessRoot.standardizedFileURL,
            extrasByBasename: extrasByBasename
        )
        return MarkdownStudyImportResult(
            markdown: staged.rewritten,
            fingerprint: fingerprint(markdown: staged.rewritten, assets: staged.assets),
            displayTitle: String(displayTitle.prefix(120)),
            missingImagePaths: staged.missing,
            assets: staged.assets
        )
    }

    /// Quick peek: does this markdown reference local image files?
    static func referencesLocalImages(in markdownURL: URL) -> Bool {
        let access = markdownURL.startAccessingSecurityScopedResource()
        defer { if access { markdownURL.stopAccessingSecurityScopedResource() } }
        guard let data = readFileData(markdownURL),
              let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { return false }
        return !localImageTargets(in: text).isEmpty
    }

    static func localImageTargets(in markdown: String) -> [String] {
        var out: [String] = []
        let specs: [(pattern: String, isEmbed: Bool)] = [
            (#"!\[([^\]]*)\]\(([^)]+)\)"#, true),
            (#"\[([^\]]*)\]\(([^)]+)\)"#, false)
        ]
        for spec in specs {
            guard let re = try? NSRegularExpression(pattern: spec.pattern) else { continue }
            let ms = re.matches(in: markdown, range: NSRange(location: 0, length: (markdown as NSString).length))
            for match in ms {
                guard match.numberOfRanges >= 3,
                      let fullRange = Range(match.range, in: markdown),
                      let targetRange = Range(match.range(at: 2), in: markdown) else { continue }
                if !spec.isEmbed, fullRange.lowerBound > markdown.startIndex {
                    let prev = markdown[markdown.index(before: fullRange.lowerBound)]
                    if prev == "!" { continue }
                }
                let target = normalizeImageTarget(String(markdown[targetRange]))
                guard isLocalImagePathCandidate(target) else { continue }
                out.append(target)
            }
        }
        return out
    }

    /// Convenience: single-file pick.
    static func importSnapshot(from sourceURL: URL, title: String? = nil) throws -> MarkdownStudyImportResult {
        let parent = sourceURL.deletingLastPathComponent()
        return try importSnapshot(markdownURL: sourceURL, accessRoot: parent, title: title)
    }

    /// Build file URL under a document folder for a Study asset link href.
    /// Accepts `https://connects.local/assets/….`, legacy `connects-asset:…`, and relative `assets/….png`.
    static func assetFileURL(documentFolder: URL, href: String) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let relative: String?
        if let special = relativePathFromSpecialScheme(href: trimmed) {
            relative = special
        } else {
            relative = relativeLocalImagePath(from: trimmed)
        }
        guard let relative, !relative.isEmpty, !relative.contains("..") else { return nil }

        let fileURL = documentFolder.appendingPathComponent(relative).standardizedFileURL
        let folderPath = documentFolder.standardizedFileURL.path
        guard fileURL.path.hasPrefix(folderPath) else { return nil }
        return fileURL
    }

    static func isStudyAssetHref(_ href: String) -> Bool {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("connects-asset:") { return true }
        if let url = URL(string: trimmed),
           url.scheme?.lowercased() == "https",
           url.host?.lowercased() == assetURLHost {
            return true
        }
        return relativeLocalImagePath(from: trimmed) != nil
    }

    /// Extract `assets/foo.png` from raw href / file URL absoluteString.
    static func relativeLocalImagePath(from raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let decoded = s.removingPercentEncoding { s = decoded }

        if let url = URL(string: s), let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                if url.host?.lowercased() == assetURLHost {
                    let p = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    return p.isEmpty ? nil : p
                }
                return nil
            }
            if scheme == "file" {
                s = url.path
            }
        }

        if let range = s.range(of: "/assets/") {
            s = String(s[range.lowerBound...].dropFirst()) // drop leading '/' → assets/...
        }
        while s.hasPrefix("./") { s = String(s.dropFirst(2)) }

        if s.hasPrefix("/") {
            if let r = s.range(of: "assets/") {
                s = String(s[r.lowerBound...])
            } else {
                return nil
            }
        }
        if s.contains("://") || s.contains("..") { return nil }

        let ext = (s as NSString).pathExtension.lowercased()
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg"]
        guard imageExts.contains(ext) else { return nil }
        return s
    }

    private static func relativePathFromSpecialScheme(href: String) -> String? {
        guard let url = URL(string: href) else { return nil }
        if url.scheme?.lowercased() == "https", url.host?.lowercased() == assetURLHost {
            let p = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return p.isEmpty ? nil : p
        }
        if url.scheme?.lowercased() == "connects-asset" {
            if let host = url.host, !host.isEmpty {
                let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return path.isEmpty ? host : "\(host)/\(path)"
            }
            var spec = url.absoluteString
            if spec.lowercased().hasPrefix("connects-asset:") {
                spec = String(spec.dropFirst("connects-asset:".count))
            }
            while spec.hasPrefix("//") { spec = String(spec.dropFirst()) }
            let p = spec.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return p.isEmpty ? nil : p
        }
        return nil
    }

    // MARK: - Private

    private struct StageResult {
        let rewritten: String
        let missing: [String]
        let localRefs: [String]
        let assets: [(relativePath: String, data: Data)]
    }

    private static func stage(_ markdown: String,
                              sourceDirectory: URL,
                              accessRoot: URL,
                              extrasByBasename: [String: Data] = [:]) throws -> StageResult {
        var missing: [String] = []
        var localRefs: [String] = []
        var assets: [(relativePath: String, data: Data)] = []
        var replaceMap: [String: (relative: String, label: String)] = [:]
        var usedNames = Set<String>()
        let rootPath = accessRoot.standardizedFileURL.path

        func ingest(target rawTarget: String, preferredLabel: String) {
            let target = normalizeImageTarget(rawTarget)
            guard !target.isEmpty, !isRemoteOrDataURL(target) else { return }
            if replaceMap[target] != nil {
                localRefs.append(target)
                return
            }
            if missing.contains(target) { return }
            localRefs.append(target)

            let resolved = sourceDirectory.appendingPathComponent(target).standardizedFileURL
            let resolvedPath = resolved.path
            let underRoot = resolvedPath == rootPath
                || resolvedPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")

            var imgData: Data?
            if underRoot {
                imgData = readFileData(resolved)
            }
            if imgData == nil || imgData?.isEmpty == true {
                let base = (target as NSString).lastPathComponent.lowercased()
                imgData = extrasByBasename[base]
            }
            guard let imgData, !imgData.isEmpty else {
                missing.append(target)
                return
            }

            var baseName = (target as NSString).lastPathComponent
            if baseName.isEmpty {
                let ext = resolved.pathExtension.isEmpty ? "png" : resolved.pathExtension.lowercased()
                baseName = "\(shortHash(imgData)).\(ext)"
            }
            if usedNames.contains(baseName) {
                let ext = (baseName as NSString).pathExtension
                let stem = (baseName as NSString).deletingPathExtension
                baseName = ext.isEmpty ? "\(stem)-\(shortHash(imgData))" : "\(stem)-\(shortHash(imgData)).\(ext)"
            }
            usedNames.insert(baseName)
            let relative = "assets/\(baseName)"
            let trimmed = preferredLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = trimmed.isEmpty ? baseName : trimmed
            replaceMap[target] = (relative, label)
            assets.append((relative, imgData))
        }

        if let imgRe = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#) {
            let ms = imgRe.matches(in: markdown, range: NSRange(location: 0, length: (markdown as NSString).length))
            for match in ms {
                guard match.numberOfRanges >= 3,
                      let targetRange = Range(match.range(at: 2), in: markdown),
                      let altRange = Range(match.range(at: 1), in: markdown) else { continue }
                ingest(target: String(markdown[targetRange]), preferredLabel: String(markdown[altRange]))
            }
        }

        if let linkRe = try? NSRegularExpression(pattern: #"\[([^\]]*)\]\(([^)]+)\)"#) {
            let ms = linkRe.matches(in: markdown, range: NSRange(location: 0, length: (markdown as NSString).length))
            for match in ms {
                guard match.numberOfRanges >= 3,
                      let fullRange = Range(match.range, in: markdown),
                      let targetRange = Range(match.range(at: 2), in: markdown),
                      let labelRange = Range(match.range(at: 1), in: markdown) else { continue }
                if fullRange.lowerBound > markdown.startIndex {
                    let prev = markdown[markdown.index(before: fullRange.lowerBound)]
                    if prev == "!" { continue }
                }
                let target = normalizeImageTarget(String(markdown[targetRange]))
                guard isLocalImagePathCandidate(target) else { continue }
                ingest(target: target, preferredLabel: String(markdown[labelRange]))
            }
        }

        var rewritten = markdown

        if let imgRe = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#) {
            let ms = imgRe.matches(in: rewritten, range: NSRange(location: 0, length: (rewritten as NSString).length))
            for match in ms.reversed() {
                guard match.numberOfRanges >= 3,
                      let fullRange = Range(match.range, in: rewritten),
                      let targetRange = Range(match.range(at: 2), in: rewritten),
                      let altRange = Range(match.range(at: 1), in: rewritten) else { continue }
                let target = normalizeImageTarget(String(rewritten[targetRange]))
                let alt = String(rewritten[altRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if isRemoteOrDataURL(target) {
                    let label = alt.isEmpty ? "图" : alt
                    rewritten.replaceSubrange(fullRange, with: "[〔图〕\(label)](\(target))")
                    continue
                }
                if let mapped = replaceMap[target] {
                    let href = "https://\(assetURLHost)/\(mapped.relative)"
                    rewritten.replaceSubrange(fullRange, with: "[〔图〕\(mapped.label)](\(href))")
                } else {
                    let label = alt.isEmpty ? (target as NSString).lastPathComponent : alt
                    rewritten.replaceSubrange(fullRange, with: "[〔图〕\(label)](\(target))")
                }
            }
        }

        if let linkRe = try? NSRegularExpression(pattern: #"\[([^\]]*)\]\(([^)]+)\)"#) {
            let ms = linkRe.matches(in: rewritten, range: NSRange(location: 0, length: (rewritten as NSString).length))
            for match in ms.reversed() {
                guard match.numberOfRanges >= 3,
                      let fullRange = Range(match.range, in: rewritten),
                      let targetRange = Range(match.range(at: 2), in: rewritten),
                      let labelRange = Range(match.range(at: 1), in: rewritten) else { continue }
                if fullRange.lowerBound > rewritten.startIndex {
                    let prev = rewritten[rewritten.index(before: fullRange.lowerBound)]
                    if prev == "!" { continue }
                }
                let target = normalizeImageTarget(String(rewritten[targetRange]))
                guard let mapped = replaceMap[target] else { continue }
                let href = "https://\(assetURLHost)/\(mapped.relative)"
                let label = String(rewritten[labelRange])
                let display = label.hasPrefix("〔图〕") ? label : "〔图〕\(label.isEmpty ? mapped.label : label)"
                rewritten.replaceSubrange(fullRange, with: "[\(display)](\(href))")
            }
        }

        return StageResult(
            rewritten: rewritten,
            missing: missing,
            localRefs: Array(Set(localRefs)),
            assets: assets
        )
    }

    private static func isLocalImagePathCandidate(_ target: String) -> Bool {
        if isRemoteOrDataURL(target) { return false }
        let ext = (normalizeImageTarget(target) as NSString).pathExtension.lowercased()
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg"]
        return imageExts.contains(ext)
    }

    private static func normalizeImageTarget(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<"), s.hasSuffix(">"), s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        if let decoded = s.removingPercentEncoding { s = decoded }
        if let re = try? NSRegularExpression(pattern: #"^(\S+)(?:\s+["'].*)?$"#),
           let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)),
           let r = Range(m.range(at: 1), in: s) {
            s = String(s[r])
        }
        return s
    }

    private static func isRemoteOrDataURL(_ target: String) -> Bool {
        let lower = target.lowercased()
        return lower.hasPrefix("http://")
            || lower.hasPrefix("https://")
            || lower.hasPrefix("data:")
            || lower.hasPrefix("mailto:")
            || lower.hasPrefix("//")
    }

    /// Coordinated read with best-effort iCloud download for ubiquitous items.
    private static func readFileData(_ url: URL) -> Data? {
        let fm = FileManager.default
        var isUbiquitous = false
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]) {
            isUbiquitous = values.isUbiquitousItem ?? false
            if isUbiquitous {
                let status = values.ubiquitousItemDownloadingStatus
                if status != .current {
                    try? fm.startDownloadingUbiquitousItem(at: url)
                    // Brief wait for small assets; large packs may still miss.
                    let deadline = Date().addingTimeInterval(2.5)
                    while Date() < deadline {
                        if let st = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus,
                           st == .current {
                            break
                        }
                        Thread.sleep(forTimeInterval: 0.15)
                    }
                }
            }
        }

        var coordinated: Data?
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readURL in
            coordinated = try? Data(contentsOf: readURL)
        }
        if let coordinated, !coordinated.isEmpty { return coordinated }
        return try? Data(contentsOf: url)
    }

    private static func fingerprint(markdown: String, assets: [(relativePath: String, data: Data)]) -> String {
        var hash: UInt64 = 5381
        let mdData = Data(markdown.utf8)
        for byte in mdData.prefix(512 * 1024) {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        for item in assets.sorted(by: { $0.relativePath < $1.relativePath }) {
            for byte in item.relativePath.utf8 {
                hash = ((hash << 5) &+ hash) &+ UInt64(byte)
            }
            hash = ((hash << 5) &+ hash) &+ UInt64(item.data.count)
            for byte in item.data.prefix(64 * 1024) {
                hash = ((hash << 5) &+ hash) &+ UInt64(byte)
            }
        }
        return "mdsnap-\(mdData.count)-\(assets.count)-\(hash)"
    }

    private static func shortHash(_ data: Data) -> String {
        var hash: UInt64 = 5381
        for byte in data.prefix(256 * 1024) {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}

/// Floating image preview card for Study asset links (dims the page, not a full-screen takeover).
final class StudyAssetImageViewController: UIViewController, UIScrollViewDelegate {
    private let image: UIImage
    private let titleText: String
    private let dimView = UIView()
    private let card = UIView()
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var cardWidthConstraint: NSLayoutConstraint!
    private var cardHeightConstraint: NSLayoutConstraint!

    init(image: UIImage, title: String) {
        self.image = image
        self.titleText = title
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        dimView.translatesAutoresizingMaskIntoConstraints = false
        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        view.addSubview(dimView)
        let tapDim = UITapGestureRecognizer(target: self, action: #selector(closeTapped))
        dimView.addGestureRecognizer(tapDim)

        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = DSTheme.c.surface
        card.layer.cornerRadius = 12
        card.clipsToBounds = true
        view.addSubview(card)

        let header = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(header)

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = titleText
        titleLabel.textColor = DSTheme.c.textPrimary
        titleLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        header.addSubview(titleLabel)

        let close = UIButton(type: .system)
        close.translatesAutoresizingMaskIntoConstraints = false
        close.setTitle("关闭", for: .normal)
        close.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        close.tintColor = DSTheme.c.accent
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        header.addSubview(close)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.backgroundColor = DSTheme.c.background
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        card.addSubview(scrollView)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)

        let maxW = min(UIScreen.main.bounds.width - 48, 720)
        let maxH = min(UIScreen.main.bounds.height * 0.72, 640)
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        var cardW = maxW
        var cardH = cardW / max(aspect, 0.01) + 44
        if cardH > maxH {
            cardH = maxH
            cardW = (cardH - 44) * aspect
            cardW = min(max(cardW, 200), maxW)
        }
        cardWidthConstraint = card.widthAnchor.constraint(equalToConstant: cardW)
        cardHeightConstraint = card.heightAnchor.constraint(equalToConstant: cardH)

        NSLayoutConstraint.activate([
            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimView.topAnchor.constraint(equalTo: view.topAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            cardWidthConstraint,
            cardHeightConstraint,

            header.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            header.topAnchor.constraint(equalTo: card.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),

            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),

            close.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            imageView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.heightAnchor)
        ])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func handleDoubleTap(_ gr: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.01 {
            scrollView.setZoomScale(1, animated: true)
        } else {
            let point = gr.location(in: imageView)
            let rect = CGRect(x: point.x - 40, y: point.y - 40, width: 80, height: 80)
            scrollView.zoom(to: rect, animated: true)
        }
    }
}
