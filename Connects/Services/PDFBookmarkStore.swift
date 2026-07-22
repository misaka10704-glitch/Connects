import Foundation

final class PDFBookmarkStore {
    static let shared = PDFBookmarkStore()

    private var cache: [String: [PDFBookmark]] = [:]
    private let ioQueue = DispatchQueue(label: "connects.pdf.bookmarks", qos: .utility)

    private var rootURL: URL {
        StudyDocumentStore.shared.studyRootURL.appendingPathComponent("bookmarks", isDirectory: true)
    }

    private init() {}

    func bookmarks(for documentID: String) -> [PDFBookmark] {
        if let cached = cache[documentID] { return cached }
        let url = bookmarkURL(for: documentID)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([PDFBookmark].self, from: data) else {
            return []
        }
        let sorted = decoded.sorted {
            if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
            return $0.createdAt < $1.createdAt
        }
        cache[documentID] = sorted
        return sorted
    }

    func add(_ bookmark: PDFBookmark, documentID: String) {
        var list = bookmarks(for: documentID)
        list.append(bookmark)
        list.sort {
            if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
            return $0.createdAt < $1.createdAt
        }
        cache[documentID] = list
        persist(documentID: documentID, bookmarks: list)
    }

    func remove(id: String, documentID: String) {
        var list = bookmarks(for: documentID)
        list.removeAll { $0.id == id }
        cache[documentID] = list
        persist(documentID: documentID, bookmarks: list)
    }

    func delete(documentID: String) {
        cache.removeValue(forKey: documentID)
        try? FileManager.default.removeItem(at: bookmarkURL(for: documentID))
    }

    private func bookmarkURL(for documentID: String) -> URL {
        rootURL.appendingPathComponent("\(documentID).json")
    }

    private func persist(documentID: String, bookmarks: [PDFBookmark]) {
        ioQueue.async {
            let folder = self.rootURL
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = self.bookmarkURL(for: documentID)
            guard let data = try? JSONEncoder().encode(bookmarks) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
