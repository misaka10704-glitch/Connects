import Foundation

enum StudyWorkspaceError: LocalizedError {
    case invalidName
    case folderUnavailable
    case fileExists
    case writeFailed
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalidName: return "文件夹或文件名无效。"
        case .folderUnavailable: return "无法访问工作区文件夹。"
        case .fileExists: return "同名文件已存在。"
        case .writeFailed: return "无法写入工作区文件。"
        case .notFound: return "找不到该文件或工作区。"
        }
    }
}

final class StudyWorkspaceStore {
    static let shared = StudyWorkspaceStore()

    private(set) var workspaces: [StudyWorkspace] = []
    private var activeFolderAccess: [String: (url: URL, accessing: Bool)] = [:]
    private let accessLock = NSLock()

    private init() {
        ConnectsPaths.ensureAppFolders()
        load()
        ensureDefault()
    }

    func workspace(id: String) -> StudyWorkspace? {
        workspaces.first { $0.id == id }
    }

    func defaultWorkspace() -> StudyWorkspace {
        ensureDefault()
        return workspaces.first { $0.isDefault } ?? StudyWorkspace.makeDefault()
    }

    @discardableResult
    func ensureDefault() -> StudyWorkspace {
        ConnectsPaths.ensureAppFolders()
        if let existing = workspaces.first(where: { $0.id == StudyWorkspace.defaultID || $0.isDefault }) {
            return existing
        }
        let ws = StudyWorkspace.makeDefault()
        workspaces.insert(ws, at: 0)
        save()
        notify()
        return ws
    }

    func folderURL(for workspaceID: String) throws -> URL {
        guard let ws = workspace(id: workspaceID) else { throw StudyWorkspaceError.notFound }
        return try resolvedFolderURL(for: ws)
    }

    func resolvedFolderURL(for ws: StudyWorkspace) throws -> URL {
        accessLock.lock()
        if let cached = activeFolderAccess[ws.id] {
            accessLock.unlock()
            return cached.url
        }
        accessLock.unlock()

        if let relative = ws.relativePath, !relative.isEmpty {
            let url = ConnectsPaths.documentsURL.appendingPathComponent(relative, isDirectory: true)
            ConnectsPaths.ensureDirectory(url)
            return url
        }
        if let data = ws.rootBookmarkData {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let accessing = url.startAccessingSecurityScopedResource()
            accessLock.lock()
            activeFolderAccess[ws.id] = (url, accessing)
            accessLock.unlock()
            if isStale {
                // Best-effort refresh on next openFolderWorkspace.
            }
            return url
        }
        throw StudyWorkspaceError.folderUnavailable
    }

    func releaseFolderAccess(for workspaceID: String) {
        accessLock.lock()
        let entry = activeFolderAccess.removeValue(forKey: workspaceID)
        accessLock.unlock()
        if let entry, entry.accessing {
            entry.url.stopAccessingSecurityScopedResource()
        }
    }

    @discardableResult
    func createFolderWorkspace(name: String) throws -> StudyWorkspace {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              trimmed != "." ,
              trimmed != ".." else {
            throw StudyWorkspaceError.invalidName
        }
        let relative = "Connects/\(trimmed)"
        let url = ConnectsPaths.documentsURL.appendingPathComponent(relative, isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) {
            // Reuse existing folder as workspace if already registered.
            if let existing = workspaces.first(where: { $0.relativePath == relative }) {
                return existing
            }
        }
        ConnectsPaths.ensureDirectory(url)
        let ws = StudyWorkspace(
            id: UUID().uuidString,
            title: trimmed,
            isDefault: false,
            rootBookmarkData: nil,
            relativePath: relative,
            documentIDs: [],
            createdAt: Date(),
            updatedAt: Date()
        )
        workspaces.insert(ws, at: 0)
        save()
        notify()
        return ws
    }

    @discardableResult
    func openFolderWorkspace(url: URL) throws -> StudyWorkspace {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let bookmark = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let title = url.lastPathComponent
        // Dedup by bookmark path string if possible.
        if let existing = workspaces.first(where: {
            !$0.isDefault && $0.title == title && $0.rootBookmarkData != nil && $0.relativePath == nil
        }) {
            var updated = existing
            updated.rootBookmarkData = bookmark
            updated.updatedAt = Date()
            replace(updated)
            _ = try scanAndSyncDocuments(workspaceID: updated.id)
            return updated
        }
        let ws = StudyWorkspace(
            id: UUID().uuidString,
            title: title,
            isDefault: false,
            rootBookmarkData: bookmark,
            relativePath: nil,
            documentIDs: [],
            createdAt: Date(),
            updatedAt: Date()
        )
        workspaces.insert(ws, at: 0)
        save()
        notify()
        _ = try scanAndSyncDocuments(workspaceID: ws.id)
        return ws
    }

    func addDocument(_ documentID: String, to workspaceID: String) {
        guard var ws = workspace(id: workspaceID) else { return }
        if !ws.documentIDs.contains(documentID) {
            ws.documentIDs.append(documentID)
            ws.updatedAt = Date()
            replace(ws)
        }
    }

    func removeDocument(_ documentID: String, from workspaceID: String) {
        guard var ws = workspace(id: workspaceID) else { return }
        ws.documentIDs.removeAll { $0 == documentID }
        ws.updatedAt = Date()
        replace(ws)
    }

    func removeDocumentFromAllWorkspaces(_ documentID: String) {
        var changed = false
        for i in workspaces.indices {
            if workspaces[i].documentIDs.contains(documentID) {
                workspaces[i].documentIDs.removeAll { $0 == documentID }
                workspaces[i].updatedAt = Date()
                changed = true
            }
        }
        if changed {
            save()
            notify()
        }
    }

    /// Create empty text file inside the workspace folder and register as StudyDocument.
    @discardableResult
    func createEmptyFile(named rawName: String, in workspaceID: String) throws -> StudyDocument {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.contains(".") {
            name += ".txt"
        }
        return try createFile(named: name, content: "", in: workspaceID)
    }

    /// Create a new file with initial UTF-8 content inside the workspace folder.
    @discardableResult
    func createFile(named rawName: String, content: String, in workspaceID: String) throws -> StudyDocument {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { throw StudyWorkspaceError.invalidName }
        if !name.contains(".") {
            name += ".md"
        }
        let folder = try folderURL(for: workspaceID)
        let dest = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            throw StudyWorkspaceError.fileExists
        }
        guard let data = content.data(using: .utf8) else {
            throw StudyWorkspaceError.writeFailed
        }
        do {
            try data.write(to: dest, options: [.atomic])
        } catch {
            throw StudyWorkspaceError.writeFailed
        }
        let doc = try StudyDocumentStore.shared.registerFileInPlace(at: dest, createEmptyIfNeeded: false)
        addDocument(doc.id, to: workspaceID)
        return doc
    }

    /// Copy an external file into the workspace folder and register.
    @discardableResult
    func importFile(from sourceURL: URL, into workspaceID: String) throws -> StudyDocument {
        let folder = try folderURL(for: workspaceID)
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
        let name = sourceURL.lastPathComponent
        var dest = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            let base = dest.deletingPathExtension().lastPathComponent
            let ext = dest.pathExtension
            var i = 2
            repeat {
                let candidate = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
                dest = folder.appendingPathComponent(candidate)
                i += 1
            } while FileManager.default.fileExists(atPath: dest.path)
        }
        do {
            try FileManager.default.copyItem(at: sourceURL, to: dest)
        } catch {
            throw StudyWorkspaceError.writeFailed
        }
        let doc = try StudyDocumentStore.shared.registerFileInPlace(at: dest, createEmptyIfNeeded: false)
        addDocument(doc.id, to: workspaceID)
        return doc
    }

    /// Scan folder for text/pdf files and register missing ones.
    @discardableResult
    func scanAndSyncDocuments(workspaceID: String) throws -> [StudyDocument] {
        let folder = try folderURL(for: workspaceID)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var added: [StudyDocument] = []
        for url in items {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true { continue }
            guard values?.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            if StudyDocument.kind(forExtension: ext) == nil, ext.isEmpty { continue }
            // Skip if already registered by path.
            if let existing = StudyDocumentStore.shared.documentMatchingPath(url.path) {
                addDocument(existing.id, to: workspaceID)
                continue
            }
            if let doc = try? StudyDocumentStore.shared.registerFileInPlace(at: url, createEmptyIfNeeded: false) {
                addDocument(doc.id, to: workspaceID)
                added.append(doc)
            }
        }
        return added
    }

    func listFileNames(in workspaceID: String) -> [String] {
        guard let folder = try? folderURL(for: workspaceID),
              let items = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return items.compactMap { url -> String? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { return nil }
            return url.lastPathComponent
        }.sorted()
    }

    /// Rename (including changing extension) a file inside the workspace folder.
    @discardableResult
    func renameFile(from oldName: String, to rawNewName: String, in workspaceID: String) throws -> StudyDocument {
        var newName = rawNewName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, !newName.contains("/"), newName != "." , newName != ".." else {
            throw StudyWorkspaceError.invalidName
        }
        if !newName.contains(".") {
            let oldExt = (oldName as NSString).pathExtension
            if !oldExt.isEmpty { newName += ".\(oldExt)" }
            else { newName += ".txt" }
        }
        let folder = try folderURL(for: workspaceID)
        let src = folder.appendingPathComponent(oldName)
        let dest = folder.appendingPathComponent(newName)
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw StudyWorkspaceError.notFound
        }
        if src.standardizedFileURL.path == dest.standardizedFileURL.path {
            if let existing = StudyDocumentStore.shared.documentMatchingPath(src.path) {
                return existing
            }
            return try StudyDocumentStore.shared.registerFileInPlace(at: src, createEmptyIfNeeded: false)
        }
        if FileManager.default.fileExists(atPath: dest.path) {
            throw StudyWorkspaceError.fileExists
        }
        do {
            try FileManager.default.moveItem(at: src, to: dest)
        } catch {
            throw StudyWorkspaceError.writeFailed
        }
        if let existing = StudyDocumentStore.shared.documentMatchingPath(src.path)
            ?? StudyDocumentStore.shared.documentMatchingPath(dest.path) {
            try StudyDocumentStore.shared.applyMovedFile(documentID: existing.id, to: dest)
            addDocument(existing.id, to: workspaceID)
            guard let updated = StudyDocumentStore.shared.document(id: existing.id) else {
                return try StudyDocumentStore.shared.registerFileInPlace(at: dest, createEmptyIfNeeded: false)
            }
            return updated
        }
        let doc = try StudyDocumentStore.shared.registerFileInPlace(at: dest, createEmptyIfNeeded: false)
        addDocument(doc.id, to: workspaceID)
        return doc
    }

    /// Delete a file from the workspace folder and detach its StudyDocument.
    func deleteFile(named name: String, in workspaceID: String) throws {
        let folder = try folderURL(for: workspaceID)
        let url = folder.appendingPathComponent(name)
        let path = url.path
        let doc = StudyDocumentStore.shared.documentMatchingPath(path)
        if FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw StudyWorkspaceError.writeFailed
            }
        }
        if let doc {
            removeDocument(doc.id, from: workspaceID)
            StudyDocumentStore.shared.delete(documentID: doc.id)
        }
    }

    // MARK: - Persistence

    private func replace(_ ws: StudyWorkspace) {
        guard let idx = workspaces.firstIndex(where: { $0.id == ws.id }) else { return }
        workspaces[idx] = ws
        save()
        notify()
    }

    private func load() {
        let url = ConnectsPaths.workspacesRegistryFileURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([StudyWorkspace].self, from: data) else {
            workspaces = []
            return
        }
        workspaces = decoded
    }

    private func save() {
        ConnectsPaths.ensureAppFolders()
        let url = ConnectsPaths.workspacesRegistryFileURL
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private func notify() {
        let post = { NotificationCenter.default.post(name: .studyWorkspacesDidUpdate, object: nil) }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }
}
