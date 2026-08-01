import Foundation
import PDFKit

enum StudyDocumentError: LocalizedError {
    case fileTooLarge
    case copyFailed
    case invalidPDF
    case invalidMarkdown
    case invalidText
    case unsupportedType
    case markdownImportAsyncOnly
    case bookmarkUnavailable
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: return "文件过大，无法打开。"
        case .copyFailed: return "无法复制文件到应用目录。"
        case .invalidPDF: return "不是有效的 PDF 文件。"
        case .invalidMarkdown: return "无法读取 Markdown 文件。"
        case .invalidText: return "无法读取文本文件。"
        case .unsupportedType: return "无法识别的文件类型。"
        case .markdownImportAsyncOnly: return "请使用「打开代码 / 文本」选择 Markdown。"
        case .bookmarkUnavailable: return "无法访问原文件，请重新打开该文档。"
        case .writeFailed: return "无法写入文件。"
        }
    }
}

struct MarkdownPDFImportOutcome {
    let document: StudyDocument
    let missingImagePaths: [String]
    /// True when an existing document was reused via fingerprint.
    let reusedExisting: Bool
}

final class StudyDocumentStore {
    static let shared = StudyDocumentStore()

    private(set) var documents: [StudyDocument] = []
    private let pdfCache = NSCache<NSString, PDFDocument>()
    private let markdownCache = NSCache<NSString, NSString>()
    private let textCache = NSCache<NSString, NSString>()
    private let maxPDFBytes: Int64 = 160 * 1024 * 1024
    private let maxTextBytes: Int64 = 8 * 1024 * 1024
    private let registryName = "registry.json"
    private var activeAccess: [String: (url: URL, accessing: Bool)] = [:]
    private let accessLock = NSLock()

    var studyRootURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("ConnectsStudy", isDirectory: true)
    }

    private init() {
        pdfCache.countLimit = 4
        markdownCache.countLimit = 8
        textCache.countLimit = 8
        loadRegistry()
    }

    func document(id: String) -> StudyDocument? {
        documents.first { $0.id == id }
    }

    func documentMatchingPath(_ path: String) -> StudyDocument? {
        let normalized = (path as NSString).standardizingPath
        return documents.first { doc in
            guard let display = doc.displayPath, !display.isEmpty else { return false }
            return (display as NSString).standardizingPath == normalized
        }
    }

    func recentDocuments(limit: Int = 50) -> [StudyDocument] {
        Array(documents.sorted { $0.lastOpenedAt > $1.lastOpenedAt }.prefix(limit))
    }

    func documents(ids: [String]) -> [StudyDocument] {
        ids.compactMap { document(id: $0) }
    }

    /// Register a file already inside a workspace folder (or create empty), using an in-place bookmark.
    @discardableResult
    func registerFileInPlace(at fileURL: URL, createEmptyIfNeeded: Bool) throws -> StudyDocument {
        let parent = fileURL.deletingLastPathComponent()
        // Only create parents inside our sandbox — never mkdir on external / security-scoped paths.
        let docs = ConnectsPaths.documentsURL.path
        if parent.path == docs || parent.path.hasPrefix(docs + "/") {
            ConnectsPaths.ensureDirectory(parent)
        }

        if createEmptyIfNeeded, !FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try Data().write(to: fileURL, options: .atomic)
            } catch {
                throw StudyDocumentError.writeFailed
            }
        }

        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }

        let ext = fileURL.pathExtension.lowercased()
        guard let kind = StudyDocument.kind(forExtension: ext) else {
            throw StudyDocumentError.unsupportedType
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = attrs[.size] as? Int64 ?? 0
        let maxBytes = kind == .pdf ? maxPDFBytes : maxTextBytes
        guard size <= maxBytes else { throw StudyDocumentError.fileTooLarge }

        if kind == .pdf, size > 0 {
            // Folder security-scope can make `PDFDocument(url:)` fail even for valid PDFs.
            // Prefer data-backed open; if that also fails, still register the bookmark so the
            // workspace file menu lists the PDF (reader surfaces errors on open).
            if PDFDocument(url: fileURL) == nil {
                if let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) {
                    _ = PDFDocument(data: data)
                }
            }
        } else if kind != .pdf, size > 0 {
            guard (try? Data(contentsOf: fileURL)) != nil else {
                throw kind == .markdown ? StudyDocumentError.invalidMarkdown : StudyDocumentError.invalidText
            }
        }

        if let existing = documentMatchingPath(fileURL.path) {
            touch(documentID: existing.id)
            return existing
        }

        // Identity is the file path — never reuse another path's document via fingerprint.
        // (Same leaf name like spi_master.v in two folders must stay distinct.)
        let fingerprint = Self.fingerprint(for: fileURL, fileSize: size)

        let bookmark = try fileURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let displayTitle = fileURL.deletingPathExtension().lastPathComponent
        let lang: StudyTextLanguage? = kind == .text || kind == .markdown
            ? StudyTextLanguage.infer(fromExtension: ext)
            : nil

        let doc = StudyDocument(
            id: UUID().uuidString,
            title: String(displayTitle.prefix(120)),
            localRelativePath: "",
            contentFingerprint: fingerprint,
            fileSize: size,
            lastOpenedAt: Date(),
            kind: kind == .markdown ? .text : kind,
            accessMode: .originalBookmark,
            bookmarkData: bookmark,
            displayPath: fileURL.path,
            textLanguage: lang
        )
        documents.insert(doc, at: 0)
        saveRegistry()
        notify()
        return doc
    }

    /// Sandbox URL for imported copies. Prefer `resolvedURL(forID:)` for reading/writing.
    func documentURL(for document: StudyDocument) -> URL {
        studyRootURL.appendingPathComponent(document.localRelativePath)
    }

    func documentURL(forID id: String) -> URL? {
        guard let doc = document(id: id) else { return nil }
        if doc.accessMode == .originalBookmark {
            return try? resolvedURL(forID: id)
        }
        guard !doc.localRelativePath.isEmpty else { return nil }
        return documentURL(for: doc)
    }

    func documentFolderURL(forID id: String) -> URL? {
        guard let doc = document(id: id) else { return nil }
        if doc.accessMode == .originalBookmark,
           let url = try? resolvedURL(forID: id) {
            return url.deletingLastPathComponent()
        }
        return studyRootURL.appendingPathComponent(id, isDirectory: true)
    }

    /// Resolve security-scoped bookmark (or sandbox copy) and keep access while document is open.
    @discardableResult
    func resolvedURL(forID id: String) throws -> URL {
        guard let doc = document(id: id) else { throw StudyDocumentError.bookmarkUnavailable }
        accessLock.lock()
        if let existing = activeAccess[id] {
            accessLock.unlock()
            return existing.url
        }
        accessLock.unlock()

        if doc.accessMode == .originalBookmark, let data = doc.bookmarkData {
            var isStale = false
            // iOS: security-scoped bookmarks from the document picker use empty creation/resolve options
            // (`.withSecurityScope` is macOS-only).
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let accessing = url.startAccessingSecurityScopedResource()
            accessLock.lock()
            activeAccess[id] = (url, accessing)
            accessLock.unlock()
            if isStale {
                if let refreshed = try? url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ), let idx = documents.firstIndex(where: { $0.id == id }) {
                    documents[idx].bookmarkData = refreshed
                    documents[idx].displayPath = url.path
                    saveRegistry()
                }
            }
            return url
        }

        guard !doc.localRelativePath.isEmpty else { throw StudyDocumentError.bookmarkUnavailable }
        let url = documentURL(for: doc)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StudyDocumentError.bookmarkUnavailable
        }
        accessLock.lock()
        activeAccess[id] = (url, false)
        accessLock.unlock()
        return url
    }

    func releaseAccess(forID id: String) {
        accessLock.lock()
        let entry = activeAccess.removeValue(forKey: id)
        accessLock.unlock()
        if let entry = entry, entry.accessing {
            entry.url.stopAccessingSecurityScopedResource()
        }
    }

    func releaseAllAccess() {
        accessLock.lock()
        let entries = activeAccess
        activeAccess.removeAll()
        accessLock.unlock()
        for (_, entry) in entries where entry.accessing {
            entry.url.stopAccessingSecurityScopedResource()
        }
    }

    func cachedPDFDocument(for documentID: String) -> PDFDocument? {
        if let cached = pdfCache.object(forKey: documentID as NSString) {
            return cached
        }
        guard let url = try? resolvedURL(forID: documentID),
              let doc = PDFDocument(url: url) else { return nil }
        pdfCache.setObject(doc, forKey: documentID as NSString)
        return doc
    }

    func invalidatePDFCache(for documentID: String) {
        pdfCache.removeObject(forKey: documentID as NSString)
    }

    func markdownText(for documentID: String) -> String? {
        textContent(for: documentID)
    }

    func textContent(for documentID: String) -> String? {
        if let cached = textCache.object(forKey: documentID as NSString)
            ?? markdownCache.object(forKey: documentID as NSString) {
            return cached as String
        }
        guard let url = try? resolvedURL(forID: documentID) else { return nil }
        var result: String?
        let coordinator = NSFileCoordinator()
        var coError: NSError?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coError) { readURL in
            guard let data = try? Data(contentsOf: readURL),
                  let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else { return }
            result = text
        }
        guard let text = result else { return nil }
        textCache.setObject(text as NSString, forKey: documentID as NSString)
        if document(id: documentID)?.kind == .markdown {
            markdownCache.setObject(text as NSString, forKey: documentID as NSString)
        }
        return text
    }

    func writeTextContent(_ text: String, for documentID: String) throws {
        let url = try resolvedURL(forID: documentID)
        let data = Data(text.utf8)
        guard Int64(data.count) <= maxTextBytes else { throw StudyDocumentError.fileTooLarge }
        var writeError: Error?
        let coordinator = NSFileCoordinator()
        var coError: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coError) { writeURL in
            do {
                try data.write(to: writeURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coError = coError { throw coError }
        if let writeError = writeError { throw writeError }
        textCache.setObject(text as NSString, forKey: documentID as NSString)
        if document(id: documentID)?.kind == .markdown {
            markdownCache.setObject(text as NSString, forKey: documentID as NSString)
        }
        if let idx = documents.firstIndex(where: { $0.id == documentID }) {
            documents[idx].fileSize = Int64(data.count)
            documents[idx].contentFingerprint = Self.fingerprint(data: data, fileSize: Int64(data.count))
            saveRegistry()
        }
    }

    func writePDFDocument(_ pdf: PDFDocument, for documentID: String) throws {
        guard let data = pdf.dataRepresentation() else { throw StudyDocumentError.writeFailed }
        try writePDFData(data, for: documentID, keepingCached: pdf)
    }

    /// Disk write only — safe off the main thread. Call after `dataRepresentation()` on main.
    func writePDFData(_ data: Data, for documentID: String, keepingCached pdf: PDFDocument? = nil) throws {
        let url = try resolvedURL(forID: documentID)
        var writeError: Error?
        let coordinator = NSFileCoordinator()
        var coError: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coError) { writeURL in
            do {
                try data.write(to: writeURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coError = coError { throw coError }
        if let writeError = writeError { throw writeError }
        if let pdf = pdf {
            pdfCache.setObject(pdf, forKey: documentID as NSString)
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64,
           let idx = documents.firstIndex(where: { $0.id == documentID }) {
            documents[idx].fileSize = size
            saveRegistry()
        }
    }

    func contentSHA8(for documentID: String) -> String {
        guard let text = textContent(for: documentID) else { return "????????" }
        var hash: UInt64 = 5381
        for byte in text.utf8.prefix(256 * 1024) {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(format: "%08llx", hash & 0xffff_ffff)
    }

    func trimCaches() {
        pdfCache.removeAllObjects()
        markdownCache.removeAllObjects()
        textCache.removeAllObjects()
    }

    /// Open original file in place (security-scoped bookmark). Prefer over import copy.
    @discardableResult
    func openDocument(from sourceURL: URL, title: String? = nil, forceText: Bool = false) throws -> StudyDocument {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let ext = sourceURL.pathExtension.lowercased()
        let kind: StudyDocumentKind
        // Code/text picker: force `.text` even when extension inference is ambiguous.
        // Markdown always uses TextCodeEditor (preview + edit), never PDF reading.
        if forceText {
            kind = .text
        } else if let inferred = StudyDocument.kind(forExtension: ext) {
            kind = inferred
        } else {
            throw StudyDocumentError.unsupportedType
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let size = attrs[.size] as? Int64 ?? 0
        let maxBytes = kind == .pdf ? maxPDFBytes : maxTextBytes
        guard size <= maxBytes else { throw StudyDocumentError.fileTooLarge }

        if kind == .pdf, size > 0 {
            // Match registerFileInPlace: don't fail open just because PDFKit can't parse via URL.
            if PDFDocument(url: sourceURL) == nil {
                if let data = try? Data(contentsOf: sourceURL, options: [.mappedIfSafe]) {
                    _ = PDFDocument(data: data)
                }
            }
        } else if kind != .pdf {
            guard (try? Data(contentsOf: sourceURL)) != nil else {
                throw kind == .markdown ? StudyDocumentError.invalidMarkdown : StudyDocumentError.invalidText
            }
        }

        let fingerprint = Self.fingerprint(for: sourceURL, fileSize: size)
        // Path is identity. Do not reuse another file's document because content/name matched.
        if let existing = documentMatchingPath(sourceURL.path) {
            touch(documentID: existing.id)
            return existing
        }

        let bookmark = try sourceURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let displayTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? sourceURL.deletingPathExtension().lastPathComponent
        let lang: StudyTextLanguage? = kind == .text ? StudyTextLanguage.infer(fromExtension: ext) : nil

        let doc = StudyDocument(
            id: UUID().uuidString,
            title: String(displayTitle.prefix(120)),
            localRelativePath: "",
            contentFingerprint: fingerprint,
            fileSize: size,
            lastOpenedAt: Date(),
            kind: kind,
            accessMode: .originalBookmark,
            bookmarkData: bookmark,
            displayPath: sourceURL.path,
            textLanguage: lang
        )
        documents.insert(doc, at: 0)
        saveRegistry()
        notify()
        return doc
    }

    /// Re-bind a document after bookmark failure by picking the same file again.
    @discardableResult
    func rebindBookmark(documentID: String, from sourceURL: URL) throws -> StudyDocument {
        guard let idx = documents.firstIndex(where: { $0.id == documentID }) else {
            return try openDocument(from: sourceURL)
        }
        releaseAccess(forID: documentID)
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
        let bookmark = try sourceURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let size = attrs[.size] as? Int64 ?? 0
        documents[idx].bookmarkData = bookmark
        documents[idx].displayPath = sourceURL.path
        documents[idx].accessMode = .originalBookmark
        documents[idx].fileSize = size
        documents[idx].contentFingerprint = Self.fingerprint(for: sourceURL, fileSize: size)
        documents[idx].lastOpenedAt = Date()
        pdfCache.removeObject(forKey: documentID as NSString)
        markdownCache.removeObject(forKey: documentID as NSString)
        textCache.removeObject(forKey: documentID as NSString)
        saveRegistry()
        notify()
        return documents[idx]
    }

    /// Import PDF based on file extension / UTI (legacy sandbox copy).
    @discardableResult
    func importDocument(from sourceURL: URL, title: String? = nil) throws -> StudyDocument {
        let ext = sourceURL.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return try importPDF(from: sourceURL, title: title)
        case "md", "markdown", "txt", "v", "vh", "sv", "c", "h", "py":
            return try openDocument(from: sourceURL, title: title)
        default:
            throw StudyDocumentError.unsupportedType
        }
    }

    @discardableResult
    func importPDF(from sourceURL: URL, title: String? = nil) throws -> StudyDocument {
        // Prefer open-in-place; fall back to copy if bookmark fails.
        if let opened = try? openDocument(from: sourceURL, title: title), opened.kind == .pdf {
            return opened
        }

        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let size = attrs[.size] as? Int64 ?? 0
        guard size <= maxPDFBytes else { throw StudyDocumentError.fileTooLarge }

        let fingerprint = Self.fingerprint(for: sourceURL, fileSize: size)
        // Imported PDF copies: reuse only another imported copy with same content hash,
        // never an in-place document that merely shares the leaf name.
        if let existing = documents.first(where: {
            $0.contentFingerprint == fingerprint && $0.accessMode == .importedCopy
        }) {
            touch(documentID: existing.id)
            return existing
        }

        let docID = UUID().uuidString
        let relative = "\(docID)/original.pdf"
        let folder = studyRootURL.appendingPathComponent(docID, isDirectory: true)
        let dest = studyRootURL.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sourceURL, to: dest)

        guard PDFDocument(url: dest) != nil else {
            try? FileManager.default.removeItem(at: folder)
            throw StudyDocumentError.invalidPDF
        }

        let displayTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? sourceURL.deletingPathExtension().lastPathComponent

        let doc = StudyDocument(
            id: docID,
            title: String(displayTitle.prefix(120)),
            localRelativePath: relative,
            contentFingerprint: fingerprint,
            fileSize: size,
            lastOpenedAt: Date(),
            kind: .pdf,
            accessMode: .importedCopy,
            displayPath: sourceURL.path
        )
        documents.insert(doc, at: 0)
        saveRegistry()
        notify()
        return doc
    }

    /// Import Markdown (.md) plus optional user-picked shared images (matched by filename).
    /// Prefer open-in-place when no extra images are needed.
    func importMarkdown(markdownURL: URL,
                        accessRoot: URL,
                        extraImageFiles: [URL] = [],
                        title: String? = nil,
                        completion: @escaping (Result<MarkdownPDFImportOutcome, Error>) -> Void) {
        if extraImageFiles.isEmpty,
           !MarkdownStudyImporter.referencesLocalImages(in: markdownURL),
           let opened = try? openDocument(from: markdownURL, title: title) {
            completion(.success(MarkdownPDFImportOutcome(
                document: opened,
                missingImagePaths: [],
                reusedExisting: false
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<MarkdownStudyImportResult, Error>
            do {
                result = .success(try MarkdownStudyImporter.importSnapshot(
                    markdownURL: markdownURL,
                    accessRoot: accessRoot,
                    extraImageFiles: extraImageFiles,
                    title: title
                ))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let snap):
                    do {
                        let outcome = try self.registerMarkdownSnapshot(snap)
                        completion(.success(outcome))
                    } catch {
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    /// Legacy single-file entry.
    func importMarkdownAsPDF(from sourceURL: URL,
                             title: String? = nil,
                             completion: @escaping (Result<MarkdownPDFImportOutcome, Error>) -> Void) {
        let root = sourceURL.deletingLastPathComponent()
        importMarkdown(markdownURL: sourceURL, accessRoot: root, title: title, completion: completion)
    }

    private func registerMarkdownSnapshot(_ snap: MarkdownStudyImportResult) throws -> MarkdownPDFImportOutcome {
        if let existing = documents.first(where: { $0.contentFingerprint == snap.fingerprint }) {
            touch(documentID: existing.id)
            return MarkdownPDFImportOutcome(
                document: existing,
                missingImagePaths: snap.missingImagePaths,
                reusedExisting: true
            )
        }

        let mdData = Data(snap.markdown.utf8)
        let mdSize = Int64(mdData.count)
        guard mdSize <= maxTextBytes else { throw StudyDocumentError.fileTooLarge }

        let docID = UUID().uuidString
        let relative = "\(docID)/original.md"
        let folder = studyRootURL.appendingPathComponent(docID, isDirectory: true)
        let dest = studyRootURL.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }

        do {
            try mdData.write(to: dest, options: .atomic)
            for asset in snap.assets {
                let assetURL = folder.appendingPathComponent(asset.relativePath)
                try FileManager.default.createDirectory(
                    at: assetURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try asset.data.write(to: assetURL, options: .atomic)
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw StudyDocumentError.copyFailed
        }

        let doc = StudyDocument(
            id: docID,
            title: snap.displayTitle,
            localRelativePath: relative,
            contentFingerprint: snap.fingerprint,
            fileSize: mdSize,
            lastOpenedAt: Date(),
            kind: .markdown,
            accessMode: .importedCopy
        )
        documents.insert(doc, at: 0)
        saveRegistry()
        notify()
        return MarkdownPDFImportOutcome(
            document: doc,
            missingImagePaths: snap.missingImagePaths,
            reusedExisting: false
        )
    }

    func touch(documentID: String) {
        guard let index = documents.firstIndex(where: { $0.id == documentID }) else { return }
        documents[index].lastOpenedAt = Date()
        documents.sort { $0.lastOpenedAt > $1.lastOpenedAt }
        saveRegistry()
        notify()
    }

    func delete(documentID: String) {
        guard let index = documents.firstIndex(where: { $0.id == documentID }) else { return }
        let doc = documents[index]
        documents.remove(at: index)
        releaseAccess(forID: documentID)
        pdfCache.removeObject(forKey: documentID as NSString)
        markdownCache.removeObject(forKey: documentID as NSString)
        textCache.removeObject(forKey: documentID as NSString)
        if doc.accessMode == .importedCopy, !doc.localRelativePath.isEmpty {
            let folder = studyRootURL.appendingPathComponent(documentID, isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
        }
        StudyProgressStore.shared.delete(documentID: documentID)
        PDFBookmarkStore.shared.delete(documentID: documentID)
        ConversationStore.shared.detachStudyDocument(documentID: documentID)
        saveRegistry()
        notify()
    }

    /// Update registry after a workspace file was moved/renamed on disk (same document id).
    func applyMovedFile(documentID: String, to newURL: URL) throws {
        guard let index = documents.firstIndex(where: { $0.id == documentID }) else {
            throw StudyWorkspaceError.notFound
        }
        let ext = newURL.pathExtension
        let kind = StudyDocument.kind(forExtension: ext) ?? .text
        let bookmark = try newURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let size = (try? newURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? documents[index].fileSize
        let displayTitle = newURL.lastPathComponent
        documents[index].title = String(displayTitle.prefix(120))
        documents[index].displayPath = newURL.path
        documents[index].bookmarkData = bookmark
        documents[index].accessMode = .originalBookmark
        documents[index].localRelativePath = ""
        documents[index].kind = kind == .markdown ? .text : kind
        documents[index].fileSize = size
        documents[index].contentFingerprint = Self.fingerprint(for: newURL, fileSize: size)
        if documents[index].kind == .text || kind == .markdown {
            documents[index].textLanguage = StudyTextLanguage.infer(fromExtension: ext)
        } else {
            documents[index].textLanguage = nil
        }
        pdfCache.removeObject(forKey: documentID as NSString)
        markdownCache.removeObject(forKey: documentID as NSString)
        textCache.removeObject(forKey: documentID as NSString)
        releaseAccess(forID: documentID)
        saveRegistry()
        notify()
    }

    func reloadAfterBackupImport() {
        releaseAllAccess()
        pdfCache.removeAllObjects()
        markdownCache.removeAllObjects()
        textCache.removeAllObjects()
        loadRegistry()
        notify()
    }

    private static func fingerprint(for url: URL, fileSize: Int64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return "\(fileSize)-\(url.path)"
        }
        defer { handle.closeFile() }
        let sample = handle.readData(ofLength: 512 * 1024)
        return fingerprint(data: sample, fileSize: fileSize, path: url.path)
    }

    private static func fingerprint(data: Data, fileSize: Int64, path: String = "", name: String = "") -> String {
        var hash: UInt64 = 5381
        for byte in data.prefix(512 * 1024) {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        // Prefer full path so same leaf names (spi_master.v) never collide across folders.
        let pathKey = path.isEmpty ? name : (path as NSString).standardizingPath
        return "\(fileSize)-\(hash)\(pathKey.isEmpty ? "" : "-\(pathKey)")"
    }

    private var registryURL: URL {
        studyRootURL.appendingPathComponent(registryName)
    }

    private func loadRegistry() {
        try? FileManager.default.createDirectory(at: studyRootURL, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: registryURL),
              let decoded = try? JSONDecoder().decode([StudyDocument].self, from: data) else {
            documents = []
            return
        }
        documents = decoded.filter { doc in
            if doc.accessMode == .originalBookmark, doc.bookmarkData != nil {
                return true
            }
            guard !doc.localRelativePath.isEmpty else { return false }
            return FileManager.default.fileExists(atPath: documentURL(for: doc).path)
        }
    }

    private func saveRegistry() {
        try? FileManager.default.createDirectory(at: studyRootURL, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(documents) else { return }
        try? data.write(to: registryURL, options: .atomic)
    }

    private func notify() {
        let post = { NotificationCenter.default.post(name: .studyDocumentsDidUpdate, object: nil) }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }

#if DEBUG
  private static let scrollStressPDFTitle = "ScrollStressHarness"

    /// One-page PDF for shell-level study stress (landscape panel + rotation).
    @discardableResult
    func debugEnsureScrollStressDocument() throws -> StudyDocument {
        if let existing = documents.first(where: { $0.title == Self.scrollStressPDFTitle }) {
            touch(documentID: existing.id)
            return existing
        }
        let docID = UUID().uuidString
        let relative = "\(docID)/original.pdf"
        let folder = studyRootURL.appendingPathComponent(docID, isDirectory: true)
        let dest = studyRootURL.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pdf = PDFDocument()
        pdf.insert(PDFPage(), at: 0)
        guard pdf.write(to: dest) else {
            throw StudyDocumentError.invalidPDF
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
        let size = attrs[.size] as? Int64 ?? 0
        let doc = StudyDocument(
            id: docID,
            title: Self.scrollStressPDFTitle,
            localRelativePath: relative,
            contentFingerprint: "scroll-stress-\(docID)",
            fileSize: size,
            lastOpenedAt: Date(),
            kind: .pdf,
            accessMode: .importedCopy
        )
        documents.insert(doc, at: 0)
        saveRegistry()
        notify()
        return doc
    }
#endif
}
