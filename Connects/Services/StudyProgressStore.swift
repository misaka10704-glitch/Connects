import Foundation

final class StudyProgressStore {
    static let shared = StudyProgressStore()

    private var cache: [String: StudyProgress] = [:]
    private var saveWorkItem: DispatchWorkItem?
    private let ioQueue = DispatchQueue(label: "connects.study.progress", qos: .utility)

    private var rootURL: URL {
        StudyDocumentStore.shared.studyRootURL.appendingPathComponent("progress", isDirectory: true)
    }

    private init() {}

    func progress(for documentID: String) -> StudyProgress? {
        if let cached = cache[documentID] { return cached }
        let url = progressURL(for: documentID)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(StudyProgress.self, from: data) else {
            return nil
        }
        cache[documentID] = decoded
        return decoded
    }

    func update(documentID: String, pageIndex: Int, pageOffsetY: CGFloat?, pageOffsetX: CGFloat? = nil, anchorX: CGFloat? = nil, anchorY: CGFloat? = nil, scaleFactor: CGFloat?) {
        let progress = StudyProgress(
            pageIndex: pageIndex,
            pageOffsetY: pageOffsetY,
            pageOffsetX: pageOffsetX,
            anchorX: anchorX,
            anchorY: anchorY,
            scaleFactor: scaleFactor,
            updatedAt: Date()
        )
        cache[documentID] = progress
        scheduleSave(documentID: documentID, progress: progress)
    }

    func update(documentID: String, progress: StudyProgress) {
        cache[documentID] = progress
        scheduleSave(documentID: documentID, progress: progress)
    }

    func trimMemory() {
        cache.removeAll()
    }

    func delete(documentID: String) {
        cache.removeValue(forKey: documentID)
        let url = progressURL(for: documentID)
        try? FileManager.default.removeItem(at: url)
    }

    private func progressURL(for documentID: String) -> URL {
        rootURL.appendingPathComponent("\(documentID).json")
    }

    private func scheduleSave(documentID: String, progress: StudyProgress) {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.persist(documentID: documentID, progress: progress)
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func persist(documentID: String, progress: StudyProgress) {
        ioQueue.async {
            let folder = self.rootURL
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = self.progressURL(for: documentID)
            guard let data = try? JSONEncoder().encode(progress) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
