import Foundation
import PDFKit

enum StudyDocumentError: LocalizedError {
    case fileTooLarge
    case copyFailed
    case invalidPDF

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: return "PDF 超过 50MB，无法导入。"
        case .copyFailed: return "无法复制 PDF 到应用目录。"
        case .invalidPDF: return "不是有效的 PDF 文件。"
        }
    }
}

final class StudyDocumentStore {
    static let shared = StudyDocumentStore()

    private(set) var documents: [StudyDocument] = []
    private let pdfCache = NSCache<NSString, PDFDocument>()
    private let maxFileBytes: Int64 = 50 * 1024 * 1024
    private let registryName = "registry.json"

    var studyRootURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("ConnectsStudy", isDirectory: true)
    }

    private init() {
        pdfCache.countLimit = 4
        loadRegistry()
    }

    func document(id: String) -> StudyDocument? {
        documents.first { $0.id == id }
    }

    func recentDocuments(limit: Int = 50) -> [StudyDocument] {
        Array(documents.sorted { $0.lastOpenedAt > $1.lastOpenedAt }.prefix(limit))
    }

    func documentURL(for document: StudyDocument) -> URL {
        studyRootURL.appendingPathComponent(document.localRelativePath)
    }

    func documentURL(forID id: String) -> URL? {
        guard let doc = document(id: id) else { return nil }
        return documentURL(for: doc)
    }

    func cachedPDFDocument(for documentID: String) -> PDFDocument? {
        if let cached = pdfCache.object(forKey: documentID as NSString) {
            return cached
        }
        guard let url = documentURL(forID: documentID),
              let doc = PDFDocument(url: url) else { return nil }
        pdfCache.setObject(doc, forKey: documentID as NSString)
        return doc
    }

    func trimCaches() {
        pdfCache.removeAllObjects()
    }

    @discardableResult
    func importPDF(from sourceURL: URL, title: String? = nil) throws -> StudyDocument {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let size = attrs[.size] as? Int64 ?? 0
        guard size <= maxFileBytes else { throw StudyDocumentError.fileTooLarge }

        let fingerprint = Self.fingerprint(for: sourceURL, fileSize: size)
        if let existing = documents.first(where: { $0.contentFingerprint == fingerprint }) {
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
            lastOpenedAt: Date()
        )
        documents.insert(doc, at: 0)
        saveRegistry()
        notify()
        return doc
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
        documents.remove(at: index)
        pdfCache.removeObject(forKey: documentID as NSString)
        let folder = studyRootURL.appendingPathComponent(documentID, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        StudyProgressStore.shared.delete(documentID: documentID)
        ConversationStore.shared.detachStudyDocument(documentID: documentID)
        saveRegistry()
        notify()
    }

    func reloadAfterBackupImport() {
        pdfCache.removeAllObjects()
        loadRegistry()
        notify()
    }

    private static func fingerprint(for url: URL, fileSize: Int64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return "\(fileSize)-\(url.lastPathComponent)"
        }
        defer { handle.closeFile() }
        let sample = handle.readData(ofLength: 512 * 1024)
        var hash: UInt64 = 5381
        for byte in sample {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return "\(fileSize)-\(hash)"
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
        documents = decoded.filter {
            FileManager.default.fileExists(atPath: documentURL(for: $0).path)
        }
    }

    private func saveRegistry() {
        try? FileManager.default.createDirectory(at: studyRootURL, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(documents) else { return }
        try? data.write(to: registryURL, options: .atomic)
    }

    private func notify() {
        NotificationCenter.default.post(name: .studyDocumentsDidUpdate, object: nil)
    }
}
