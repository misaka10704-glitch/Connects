import Foundation
import UIKit

/// Persists EPUB reading annotations inside the package (`META-INF/…`) plus a Study sidecar fallback.
enum EPUBAnnotationStore {
    static let packageJSONPath = "META-INF/com.connects.annotations.json"

    private struct Envelope: Codable {
        var version: Int
        var annotations: [ReadingAnnotation]
        /// Ids the user deleted.
        ///
        /// Loading merges the package and the sidecar, and a merge of two lists can
        /// only ever add. Without an explicit record of what was removed, deleting an
        /// annotation in the sidebar just meant it came back from the other copy.
        var deletedIDs: [String]?
    }

    // MARK: - Public

    /// Load annotations from the EPUB package and/or Study sidecar (merge by id, newer wins).
    static func load(epubURL: URL, documentID: String?) -> [ReadingAnnotation] {
        var byID: [String: ReadingAnnotation] = [:]
        var deleted: Set<String> = []
        if let package = (try? readPackageEnvelope(from: epubURL)) {
            for a in package.annotations { byID[a.id] = a }
            deleted.formUnion(package.deletedIDs ?? [])
        }
        if let documentID, let sidecar = (try? readSidecarEnvelope(documentID: documentID)) {
            for a in sidecar.annotations {
                if let existing = byID[a.id] {
                    if a.updatedAt >= existing.updatedAt { byID[a.id] = a }
                } else {
                    byID[a.id] = a
                }
            }
            deleted.formUnion(sidecar.deletedIDs ?? [])
        }
        for id in deleted { byID.removeValue(forKey: id) }
        return byID.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// Ids deleted so far, so a caller can keep carrying them forward.
    static func loadDeletedIDs(epubURL: URL, documentID: String?) -> Set<String> {
        var deleted: Set<String> = []
        if let package = (try? readPackageEnvelope(from: epubURL)) {
            deleted.formUnion(package.deletedIDs ?? [])
        }
        if let documentID, let sidecar = (try? readSidecarEnvelope(documentID: documentID)) {
            deleted.formUnion(sidecar.deletedIDs ?? [])
        }
        return deleted
    }

    /// Persist annotations to the Study sidecar.
    ///
    ///每次划线都重打包整本书会不停改写文件、让预览缓存 key 失效；因此这里只写
    /// sidecar，写回书籍交给 `flushToPackage`（关闭阅读器时调用一次）。
    @discardableResult
    static func save(
        _ annotations: [ReadingAnnotation],
        epubURL: URL,
        documentID: String?,
        deletedIDs: Set<String> = []
    ) -> URL? {
        _ = epubURL
        if let documentID {
            try? writeSidecar(annotations, deletedIDs: deletedIDs, documentID: documentID)
        }
        return nil
    }

    /// Write annotations back into the book itself so they travel with the file.
    ///
    /// The whole archive has to be rebuilt, so the result is verified before it is
    /// allowed anywhere near the original: if the rebuilt package is missing
    /// entries, or its chapters no longer read back, the user's book is left
    /// untouched and the sidecar remains the source of truth.
    @discardableResult
    static func flushToPackage(
        _ annotations: [ReadingAnnotation],
        epubURL: URL,
        deletedIDs: Set<String> = []
    ) -> Bool {
        let accessing = epubURL.startAccessingSecurityScopedResource()
        defer { if accessing { epubURL.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("connects-epub-flush-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }

        do {
            let unpacked = work.appendingPathComponent("pkg", isDirectory: true)
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try SimpleZip.unzip(archiveURL: epubURL, to: unpacked)

            guard try packageEntryNames(in: unpacked).contains("mimetype") else { return false }

            let jsonURL = unpacked.appendingPathComponent(packageJSONPath)
            try fm.createDirectory(
                at: jsonURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let payload = try JSONEncoder().encode(Envelope(
                version: 1,
                annotations: annotations,
                deletedIDs: deletedIDs.isEmpty ? nil : deletedIDs.sorted()
            ))
            try payload.write(to: jsonURL, options: .atomic)

            let rebuilt = work.appendingPathComponent("rebuilt.epub")
            try SimpleZip.zip(directory: unpacked, to: rebuilt)
            guard verifyPackage(at: rebuilt, matches: unpacked) else { return false }

            _ = try fm.replaceItemAt(epubURL, withItemAt: rebuilt)
            return true
        } catch {
            return false
        }
    }

    private static func packageEntryNames(in directory: URL) throws -> Set<String> {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        var names: Set<String> = []
        let base = directory.standardizedFileURL.path
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            names.insert(String(path.dropFirst(base.count).drop(while: { $0 == "/" })))
        }
        return names
    }

    /// A rebuilt package may only replace a book if it unzips back to exactly the
    /// tree it was built from — same entries, same bytes. Anything less and we keep
    /// the original: a mangled chapter costs the reader the whole book.
    private static func verifyPackage(at archiveURL: URL, matches source: URL) -> Bool {
        let fm = FileManager.default
        let check = fm.temporaryDirectory
            .appendingPathComponent("connects-epub-verify-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: check) }
        do {
            try fm.createDirectory(at: check, withIntermediateDirectories: true)
            try SimpleZip.unzip(archiveURL: archiveURL, to: check)

            let expected = try packageEntryNames(in: source)
            guard try packageEntryNames(in: check) == expected else { return false }
            for name in expected {
                let lhs = try Data(contentsOf: source.appendingPathComponent(name))
                let rhs = try Data(contentsOf: check.appendingPathComponent(name))
                guard lhs == rhs else { return false }
            }
            let mimetype = try Data(contentsOf: check.appendingPathComponent("mimetype"))
            return String(data: mimetype, encoding: .utf8)?.hasPrefix("application/epub+zip") == true
        } catch {
            return false
        }
    }

    // MARK: - Sidecar

    private static func sidecarDirectory() throws -> URL {
        let dir = StudyDocumentStore.shared.studyRootURL
            .appendingPathComponent("epub-ann", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func sidecarURL(documentID: String) throws -> URL {
        try sidecarDirectory().appendingPathComponent("\(documentID).json")
    }

    private static func readSidecarEnvelope(documentID: String) throws -> Envelope {
        let url = try sidecarURL(documentID: documentID)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Envelope.self, from: data)
    }

    private static func writeSidecar(
        _ annotations: [ReadingAnnotation],
        deletedIDs: Set<String>,
        documentID: String
    ) throws {
        let env = Envelope(
            version: 1,
            annotations: annotations,
            deletedIDs: deletedIDs.isEmpty ? nil : deletedIDs.sorted()
        )
        let data = try JSONEncoder().encode(env)
        try data.write(to: try sidecarURL(documentID: documentID), options: .atomic)
    }

    // MARK: - Package JSON / rewrite

    private static func readPackageEnvelope(from epubURL: URL) throws -> Envelope {
        let accessing = epubURL.startAccessingSecurityScopedResource()
        defer { if accessing { epubURL.stopAccessingSecurityScopedResource() } }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectsEPUBAnnRead-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try SimpleZip.unzip(archiveURL: epubURL, to: staging)
        let jsonURL = staging.appendingPathComponent(packageJSONPath)
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            return Envelope(version: 1, annotations: [], deletedIDs: nil)
        }
        let data = try Data(contentsOf: jsonURL)
        return try JSONDecoder().decode(Envelope.self, from: data)
    }
}
