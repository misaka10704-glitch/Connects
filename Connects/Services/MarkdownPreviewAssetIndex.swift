import Foundation
import UIKit
import WebKit

/// Indexes `./assets` (Typora) and `./asset` next to a Markdown file so preview
/// can render `![alt](./assets/foo.png)` as inline images instead of 〔图〕 chips.
enum MarkdownPreviewAssetIndex {
    static let scheme = "connects-mdasset"
    static let folderNames = ["assets", "asset"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg"]

    struct Catalog {
        let documentFolder: URL
        /// `assets/foo.png` → file URL
        let byRelative: [String: URL]
        /// `foo.png` → file URL (prefers `assets/` over `asset/`)
        let byBasename: [String: URL]
    }

    static func catalog(documentFolder: URL) -> Catalog {
        let folder = documentFolder.standardizedFileURL
        var byRelative: [String: URL] = [:]
        var byBasename: [String: URL] = [:]
        let fm = FileManager.default

        func addFile(_ url: URL) {
            let ext = url.pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { return }
            let std = url.standardizedFileURL
            guard let rel = relativePath(of: std, under: folder) else { return }
            byRelative[rel] = std
            byRelative[rel.lowercased()] = std
            let base = std.lastPathComponent.lowercased()
            if byBasename[base] == nil {
                byBasename[base] = std
            }
        }

        for name in folderNames {
            let dir = folder.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            var count = 0
            for case let url as URL in enumerator {
                let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? true
                guard isFile else { continue }
                addFile(url)
                count += 1
                if count >= 800 { break }
            }
        }

        if let kids = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in kids {
                let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                if isFile { addFile(url) }
            }
        }

        return Catalog(documentFolder: folder, byRelative: byRelative, byBasename: byBasename)
    }

    /// Rewrite Typora-style `![…](./assets/…)` (and leftover 〔图〕 links) to the preview scheme.
    static func rewriteForPreview(_ markdown: String, catalog: Catalog?) -> String {
        var rewritten = markdown
        if let imgRe = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#) {
            let ms = imgRe.matches(in: rewritten, range: NSRange(location: 0, length: (rewritten as NSString).length))
            for match in ms.reversed() {
                guard match.numberOfRanges >= 3,
                      let fullRange = Range(match.range, in: rewritten),
                      let targetRange = Range(match.range(at: 2), in: rewritten),
                      let altRange = Range(match.range(at: 1), in: rewritten) else { continue }
                let target = normalizeTarget(String(rewritten[targetRange]))
                guard let href = previewHref(for: target, catalog: catalog) else { continue }
                let alt = String(rewritten[altRange])
                rewritten.replaceSubrange(fullRange, with: "![\(alt)](\(href))")
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
                let target = normalizeTarget(String(rewritten[targetRange]))
                guard let href = previewHref(for: target, catalog: catalog) else { continue }
                var alt = String(rewritten[labelRange])
                if alt.hasPrefix("〔图〕") {
                    alt = String(alt.dropFirst("〔图〕".count))
                }
                rewritten.replaceSubrange(fullRange, with: "![\(alt)](\(href))")
            }
        }
        return rewritten
    }

    static func isPreviewAssetHref(_ href: String) -> Bool {
        href.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("\(scheme):")
    }

    static func fileURL(for href: String, catalog: Catalog?) -> URL? {
        guard let catalog else { return nil }
        if let rel = relativePathFromHref(href) {
            if let url = resolve(rel, catalog: catalog) { return url }
        }
        let target = normalizeTarget(href)
        return resolve(target, catalog: catalog)
    }

    static func loadImage(href: String, catalog: Catalog?) -> (image: UIImage, title: String)? {
        guard let url = fileURL(for: href, catalog: catalog),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        return (image, url.deletingPathExtension().lastPathComponent)
    }

    static func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "svg": return "image/svg+xml"
        default: return "image/png"
        }
    }

    // MARK: - Private

    static func previewHref(for rawTarget: String, catalog: Catalog?) -> String? {
        let target = normalizeTarget(rawTarget)
        if target.isEmpty { return nil }
        if isRemoteNonAsset(target) { return nil }
        if isPreviewAssetHref(target) { return target }
        if let rel = relativePathFromHref(target) {
            if let resolved = resolve(rel, catalog: catalog) {
                return schemeURL(relativePath: relativePath(of: resolved, under: catalog?.documentFolder) ?? rel)
            }
            return schemeURL(relativePath: posixRelative(rel))
        }
        if let resolved = resolve(target, catalog: catalog) {
            let rel = relativePath(of: resolved, under: catalog?.documentFolder)
                ?? posixRelative(target)
            return schemeURL(relativePath: rel)
        }
        let posix = posixRelative(target)
        guard looksLikeLocalImage(posix) else { return nil }
        return schemeURL(relativePath: posix)
    }

    private static func resolve(_ raw: String, catalog: Catalog?) -> URL? {
        let posix = posixRelative(raw)
        guard !posix.isEmpty, !posix.contains("..") else { return nil }
        if let catalog {
            if let url = catalog.byRelative[posix] ?? catalog.byRelative[posix.lowercased()] {
                return url
            }
            let base = (posix as NSString).lastPathComponent.lowercased()
            if !base.isEmpty, let url = catalog.byBasename[base] {
                return url
            }
            let folder = catalog.documentFolder
            let direct = folder.appendingPathComponent(posix).standardizedFileURL
            if isInside(direct, folder: folder), FileManager.default.fileExists(atPath: direct.path) {
                return direct
            }
            if !base.isEmpty {
                for name in folderNames {
                    let candidate = folder.appendingPathComponent(name).appendingPathComponent(base)
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        return candidate.standardizedFileURL
                    }
                }
            }
        }
        return nil
    }

    private static func schemeURL(relativePath: String) -> String {
        let encoded = relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return "\(scheme)://preview/\(encoded)"
    }

    private static func relativePathFromHref(_ href: String) -> String? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if isPreviewAssetHref(trimmed), let url = URL(string: trimmed) {
            var path = url.path
            if path.hasPrefix("/") { path = String(path.dropFirst()) }
            if let decoded = path.removingPercentEncoding { path = decoded }
            return path.isEmpty ? nil : path
        }
        if let special = MarkdownStudyImporter.relativeLocalImagePath(from: trimmed) {
            return posixRelative(special)
        }
        return nil
    }

    private static func posixRelative(_ raw: String) -> String {
        var s = normalizeTarget(raw)
        if let decoded = s.removingPercentEncoding { s = decoded }
        while s.hasPrefix("./") { s = String(s.dropFirst(2)) }
        if s.hasPrefix("/") { s = String(s.dropFirst()) }
        return s.replacingOccurrences(of: "\\", with: "/")
    }

    private static func normalizeTarget(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<"), s.hasSuffix(">"), s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        if let re = try? NSRegularExpression(pattern: #"^(\S+)(?:\s+["'].*)?$"#),
           let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)),
           let r = Range(m.range(at: 1), in: s) {
            s = String(s[r])
        }
        return s
    }

    private static func looksLikeLocalImage(_ path: String) -> Bool {
        if isRemoteNonAsset(path) { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    private static func isRemoteNonAsset(_ target: String) -> Bool {
        let lower = target.lowercased()
        if lower.hasPrefix("data:") || lower.hasPrefix("mailto:") { return true }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            if let url = URL(string: target), url.host?.lowercased() == MarkdownStudyImporter.assetURLHost {
                return false
            }
            return true
        }
        return false
    }

    private static func relativePath(of file: URL, under folder: URL?) -> String? {
        guard let folder else { return nil }
        let filePath = file.standardizedFileURL.path
        let folderPath = folder.standardizedFileURL.path
        guard isInside(file, folder: folder) else { return nil }
        var rel = String(filePath.dropFirst(folderPath.count))
        if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
        return rel.isEmpty ? nil : rel
    }

    private static func isInside(_ file: URL, folder: URL) -> Bool {
        let filePath = file.standardizedFileURL.path
        let folderPath = folder.standardizedFileURL.path
        if filePath == folderPath { return false }
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        return filePath.hasPrefix(prefix)
    }
}

/// Serves `connects-mdasset://preview/assets/…` from the indexed document folder.
final class MarkdownPreviewAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    var catalog: MarkdownPreviewAssetIndex.Catalog?
    private var stopped = Set<ObjectIdentifier>()
    private let lock = NSLock()

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let token = ObjectIdentifier(urlSchemeTask)
        guard let requestURL = urlSchemeTask.request.url,
              let fileURL = MarkdownPreviewAssetIndex.fileURL(for: requestURL.absoluteString, catalog: catalog),
              let data = try? Data(contentsOf: fileURL),
              !data.isEmpty else {
            finish(urlSchemeTask, token: token, error: URLError(.fileDoesNotExist))
            return
        }
        let mime = MarkdownPreviewAssetIndex.mimeType(for: fileURL)
        let response = URLResponse(
            url: requestURL,
            mimeType: mime,
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        finish(urlSchemeTask, token: token, response: response, data: data)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        lock.lock()
        stopped.insert(ObjectIdentifier(urlSchemeTask))
        lock.unlock()
    }

    private func finish(_ task: WKURLSchemeTask,
                        token: ObjectIdentifier,
                        response: URLResponse? = nil,
                        data: Data? = nil,
                        error: Error? = nil) {
        lock.lock()
        let cancelled = stopped.contains(token)
        if cancelled { stopped.remove(token) }
        lock.unlock()
        guard !cancelled else { return }
        if let error {
            task.didFailWithError(error)
            return
        }
        if let response { task.didReceive(response) }
        if let data { task.didReceive(data) }
        task.didFinish()
    }
}
