import Foundation
import ReadiumShared
import ReadiumStreamer
import UIKit

enum ReadiumEbookError: LocalizedError {
    case invalidURL
    case retrieveFailed(String)
    case openFailed(String)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的电子书路径"
        case .retrieveFailed(let m): return "无法读取电子书：\(m)"
        case .openFailed(let m): return "无法打开 EPUB：\(m)"
        case .copyFailed(let m): return "无法准备 EPUB 副本：\(m)"
        }
    }
}

/// Opens local EPUB files via Readium Streamer.
///
/// PDF/TXT prove the Study file URL is generally readable. EPUB still needs a
/// different path: Readium opens a **ZIP with random access** (central directory
/// at the end). Feeding the original Files URL straight in has produced a
/// "successful" Publication with **empty readingOrder** on device.
///
/// Fix: read full bytes the same way TXT does (`Data` + file coordinator),
/// write an ASCII-named sandbox `.epub`, then open that with an explicit
/// `application/epub+zip` hint.
///
/// ## Preview cache vs source package
/// The reader always serves from `ConnectsEPUB/cached-*.epub`. Annotation
/// write-back updates the *source* package (and sidecar) but must **not** delete
/// the cache file a live `Publication` is still reading — otherwise decorations
/// / page loads silently break mid-session.
enum ReadiumEbookOpener {
    private static let httpClient = DefaultHTTPClient()
    private static let assetRetriever = AssetRetriever(httpClient: httpClient)
    private static let publicationOpener = PublicationOpener(
        parser: DefaultPublicationParser(
            httpClient: httpClient,
            assetRetriever: assetRetriever,
            pdfFactory: DefaultPDFDocumentFactory()
        )
    )

    /// Paths of cache files currently opened by a reader session.
    private static var activeCachePaths = Set<String>()
    /// In-process source paths needing a preview rebuild (also mirrored to disk markers).
    private static var staleSourcePaths = Set<String>()
    private static let lock = NSLock()

    private static func connectsEPUBCacheDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ConnectsEPUB", isDirectory: true)
    }

    private static func staleMarkerURL(for source: URL) -> URL {
        let digest = StableEPUBCacheKey.fnv1a64(source.standardizedFileURL.path)
        return connectsEPUBCacheDirectory().appendingPathComponent("stale-\(digest).flag")
    }

    /// Mark the preview cache for `source` as out of date. Safe while a reader is open.
    /// Survives process death via a flag file next to `cached-*.epub`.
    static func markPreviewCacheStale(for source: URL) {
        let path = source.standardizedFileURL.path
        lock.lock()
        staleSourcePaths.insert(path)
        lock.unlock()
        let dir = connectsEPUBCacheDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data([0x31]).write(to: staleMarkerURL(for: source), options: .atomic)
    }

    private static func clearPreviewCacheStale(for source: URL) {
        let path = source.standardizedFileURL.path
        lock.lock()
        staleSourcePaths.remove(path)
        lock.unlock()
        try? FileManager.default.removeItem(at: staleMarkerURL(for: source))
    }

    private static func isPreviewCacheStale(for source: URL) -> Bool {
        let path = source.standardizedFileURL.path
        lock.lock()
        let mem = staleSourcePaths.contains(path)
        lock.unlock()
        if mem { return true }
        return FileManager.default.fileExists(atPath: staleMarkerURL(for: source).path)
    }

    /// Drop the stable temp copy so the next open re-reads package bytes (e.g. after annotation write-back).
    /// If the cache is still pinned by a live reader, only marks it stale for the next open.
    static func invalidateCachedCopy(of source: URL) {
        let fm = FileManager.default
        let dir = connectsEPUBCacheDirectory()
        guard let values = try? source.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
        ]) else {
            markPreviewCacheStale(for: source)
            removeInactiveCaches(in: dir)
            return
        }
        let size = values.fileSize ?? 0
        let mtime = Int((values.contentModificationDate ?? .distantPast).timeIntervalSince1970)
        let stamp = "\(size)-\(mtime)-\(source.lastPathComponent)"
        let digest = StableEPUBCacheKey.fnv1a64(stamp)
        let dest = dir.appendingPathComponent("cached-\(digest).epub")
        lock.lock()
        let active = activeCachePaths.contains(dest.path)
        lock.unlock()
        if active {
            markPreviewCacheStale(for: source)
            return
        }
        try? fm.removeItem(at: dest)
        clearPreviewCacheStale(for: source)
    }

    /// Result of opening: publication + the sandbox cache file Readium is serving.
    struct OpenedEPUB {
        let publication: Publication
        /// `ConnectsEPUB/cached-*.epub` — keep this file until `releaseCache`.
        let cacheURL: URL
        /// Original Study / Files URL the user picked.
        let sourceURL: URL
    }

    static func openEPUB(at fileURL: URL) async throws -> OpenedEPUB {
        // Nested with StudyDocumentStore's activeAccess: each successful start needs one stop.
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        let localURL = try await copyToStableTempEPUB(from: fileURL)
        guard let file = FileURL(url: localURL) else {
            throw ReadiumEbookError.invalidURL
        }

        let asset: Asset
        switch await assetRetriever.retrieve(url: file, mediaType: .epub) {
        case .success(let value):
            asset = value
        case .failure(let error):
            throw ReadiumEbookError.retrieveFailed(String(describing: error))
        }

        switch await publicationOpener.open(
            asset: asset,
            allowUserInteraction: false,
            sender: nil as UIView?
        ) {
        case .success(let publication):
            guard !publication.readingOrder.isEmpty else {
                let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.intValue ?? -1
                throw ReadiumEbookError.openFailed(
                    "EPUB 没有可读章节（readingOrder=0, resources=\(publication.resources.count), bytes=\(size), format=\(asset.format)）"
                )
            }
            pinCache(localURL)
            return OpenedEPUB(publication: publication, cacheURL: localURL, sourceURL: fileURL)
        case .failure(let error):
            throw ReadiumEbookError.openFailed(String(describing: error))
        }
    }

    /// Call when the reader tears down so future invalidate can delete the cache.
    static func releaseCache(_ cacheURL: URL?) {
        guard let cacheURL else { return }
        lock.lock()
        activeCachePaths.remove(cacheURL.path)
        let shouldDelete = !staleSourcePaths.isEmpty
        lock.unlock()
        // Also honor on-disk stale markers (process may have been killed mid-session).
        let dir = connectsEPUBCacheDirectory()
        let hasDiskStale: Bool = {
            guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { return false }
            return items.contains { $0.lastPathComponent.hasPrefix("stale-") && $0.pathExtension == "flag" }
        }()
        if shouldDelete || hasDiskStale {
            try? FileManager.default.removeItem(at: cacheURL)
        }
    }

    private static func pinCache(_ url: URL) {
        lock.lock()
        activeCachePaths.insert(url.path)
        lock.unlock()
    }

    private static func removeInactiveCaches(in dir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        lock.lock()
        let active = activeCachePaths
        lock.unlock()
        for url in items where url.pathExtension.lowercased() == "epub" {
            if active.contains(url.path) { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// Copy into app tmp with an ASCII `.epub` name so Readium always sees a full local ZIP.
    /// Reuses an existing temp copy when source path/size/mtime match (cold reopen).
    private static func copyToStableTempEPUB(from source: URL) async throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ConnectsEPUB", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // iCloud / Files placeholders: force download before reading bytes.
        var values = try source.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        if values.isUbiquitousItem == true {
            try? fm.startDownloadingUbiquitousItem(at: source)
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                values = try source.resourceValues(forKeys: [
                    .ubiquitousItemDownloadingStatusKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                ])
                if values.ubiquitousItemDownloadingStatus == .current {
                    break
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        let size = values.fileSize ?? 0
        let mtime = Int((values.contentModificationDate ?? .distantPast).timeIntervalSince1970)
        let stamp = "\(size)-\(mtime)-\(source.lastPathComponent)"
        let digest = StableEPUBCacheKey.fnv1a64(stamp)
        let dest = dir.appendingPathComponent("cached-\(digest).epub")

        let forceRefresh = isPreviewCacheStale(for: source)
        if forceRefresh {
            try? fm.removeItem(at: dest)
            // Drop other inactive preview copies so we never reopen a pre-annotation ZIP.
            removeInactiveCaches(in: dir)
            clearPreviewCacheStale(for: source)
        } else if size > 64,
           fm.fileExists(atPath: dest.path),
           let attrs = try? fm.attributesOfItem(atPath: dest.path),
           let destSize = attrs[.size] as? NSNumber,
           destSize.intValue == size
        {
            return dest
        }

        let data: Data = try await withCheckedThrowingContinuation { cont in
            var coordinatorError: NSError?
            var readError: Error?
            var result: Data?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: source, options: [], error: &coordinatorError) { url in
                do {
                    // Unmapped read: mapped/iCloud placeholders can look like a ZIP header
                    // but yield incomplete central directories on device.
                    let bytes = try Data(contentsOf: url, options: [])
                    result = bytes
                } catch {
                    readError = error
                }
            }
            if let coordinatorError {
                cont.resume(throwing: ReadiumEbookError.copyFailed(coordinatorError.localizedDescription))
            } else if let readError {
                cont.resume(throwing: ReadiumEbookError.copyFailed(readError.localizedDescription))
            } else if let result {
                cont.resume(returning: result)
            } else {
                cont.resume(throwing: ReadiumEbookError.copyFailed("无法读取源文件"))
            }
        }

        guard data.count > 64 else {
            throw ReadiumEbookError.copyFailed("源文件过小（\(data.count) bytes）— 可能未从 iCloud 下完或无权访问")
        }
        let isZip = data[0] == 0x50 && data[1] == 0x4b
        guard isZip else {
            throw ReadiumEbookError.copyFailed("不是 ZIP/EPUB 文件头")
        }
        try? fm.removeItem(at: dest)
        try data.write(to: dest, options: .atomic)
        let writtenSize = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.intValue ?? -1
        guard writtenSize == data.count else {
            throw ReadiumEbookError.copyFailed("副本不完整（\(writtenSize)/\(data.count)）")
        }
        return dest
    }
}

private enum StableEPUBCacheKey {
    static func fnv1a64(_ string: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for b in string.utf8 {
            hash ^= UInt64(b)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
