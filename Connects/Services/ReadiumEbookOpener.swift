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

    static func openEPUB(at fileURL: URL) async throws -> Publication {
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
            return publication
        case .failure(let error):
            throw ReadiumEbookError.openFailed(String(describing: error))
        }
    }

    /// Copy into app tmp with an ASCII `.epub` name so Readium always sees a full local ZIP.
    private static func copyToStableTempEPUB(from source: URL) async throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ConnectsEPUB", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(UUID().uuidString).epub")

        // iCloud / Files placeholders: force download before reading bytes.
        var values = try source.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .fileSizeKey,
        ])
        if values.isUbiquitousItem == true {
            try? fm.startDownloadingUbiquitousItem(at: source)
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                values = try source.resourceValues(forKeys: [
                    .ubiquitousItemDownloadingStatusKey,
                    .fileSizeKey,
                ])
                if values.ubiquitousItemDownloadingStatus == .current {
                    break
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
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
        try data.write(to: dest, options: .atomic)
        let written = try Data(contentsOf: dest, options: [])
        guard written.count == data.count else {
            throw ReadiumEbookError.copyFailed("副本不完整（\(written.count)/\(data.count)）")
        }
        return dest
    }
}
