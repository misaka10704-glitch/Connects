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
            do {
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
                return url
            } catch {
                // Fall through to absoluteRootPath when bookmark resolve fails.
            }
        }
        if let absolute = ws.absoluteRootPath, !absolute.isEmpty {
            let url = URL(fileURLWithPath: absolute, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                accessLock.lock()
                activeFolderAccess[ws.id] = (url, false)
                accessLock.unlock()
                return url
            }
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
            absoluteRootPath: nil,
            documentIDs: [],
            lastOpenedDocumentID: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        workspaces.insert(ws, at: 0)
        save()
        notify()
        return ws
    }

    @discardableResult
    func openFolderWorkspace(url: URL, asProjectGrant: Bool = false) throws -> StudyWorkspace {
        // IMPORTANT: keep security-scoped access alive in `activeFolderAccess`.
        let accessing = url.startAccessingSecurityScopedResource()

        let openedPath = Self.normalizedPath(url.path)
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !exists && !accessing {
            throw StudyWorkspaceError.folderUnavailable
        }

        // Unscoped parent-of-file (DSP(NJU)) must not steal the real grant (Workspace/).
        if !accessing, !asProjectGrant, let grant = bookmarkedWorkspaceCovering(path: openedPath) {
            _ = try? folderURL(for: grant.id)
            return grant
        }

        let title = url.lastPathComponent
        // Always try bookmark — on Mac Catalyst `startAccessing` often returns false
        // even for a valid user-selected folder; still persist scope when possible.
        let bookmark: Data? = (accessing || asProjectGrant)
            ? (try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ))
            : nil

        let ws: StudyWorkspace
        if let existing = workspaces.first(where: { candidate in
            guard !candidate.isDefault else { return false }
            if let abs = candidate.absoluteRootPath, Self.normalizedPath(abs) == openedPath {
                return true
            }
            guard let existingURL = try? folderURL(for: candidate.id) else { return false }
            return Self.normalizedPath(existingURL.path) == openedPath
        }) {
            var updated = existing
            if let bookmark {
                updated.rootBookmarkData = bookmark
            }
            // Keep wider absolute root if we somehow matched a bookmarked parent record.
            if updated.rootBookmarkData == nil || accessing || asProjectGrant {
                updated.absoluteRootPath = openedPath
            }
            if accessing || asProjectGrant {
                updated.title = title
            }
            updated.updatedAt = Date()
            replace(updated)
            ws = updated
        } else if !accessing, !asProjectGrant, let grant = bookmarkedWorkspaceCovering(path: openedPath) {
            _ = try? folderURL(for: grant.id)
            return grant
        } else if !asProjectGrant, !accessing, bookmark == nil,
                  let covering = workspaceWithDirectoryAccess(coveringFilePath: openedPath),
                  covering.rootBookmarkData != nil || covering.absoluteRootPath != nil {
            _ = try? folderURL(for: covering.id)
            return covering
        } else {
            let created = StudyWorkspace(
                id: UUID().uuidString,
                title: title,
                isDefault: false,
                rootBookmarkData: bookmark,
                relativePath: nil,
                absoluteRootPath: openedPath,
                documentIDs: [],
                lastOpenedDocumentID: nil,
                createdAt: Date(),
                updatedAt: Date()
            )
            workspaces.insert(created, at: 0)
            save()
            notify()
            ws = created
        }

        accessLock.lock()
        if let prev = activeFolderAccess[ws.id], prev.accessing {
            if Self.normalizedPath(prev.url.path) != openedPath {
                prev.url.stopAccessingSecurityScopedResource()
            }
        }
        activeFolderAccess[ws.id] = (url, accessing)
        accessLock.unlock()

        if asProjectGrant || accessing {
            markAsProjectFolderGrant(ws.id)
        }
        return ws
    }

    private static let projectFolderGrantFlagKey = "Connects.hasProjectFolderGrant"
    private static let projectFolderWorkspaceIDKey = "Connects.projectFolderWorkspaceID"

    /// Remember the workspace chosen via the system folder picker (not in-app `Connects/…` folders).
    func markAsProjectFolderGrant(_ workspaceID: String) {
        UserDefaults.standard.set(workspaceID, forKey: Self.projectFolderWorkspaceIDKey)
        UserDefaults.standard.set(true, forKey: Self.projectFolderGrantFlagKey)
    }

    /// True for user-selected external project roots (excludes `Connects/SPI_E2E…` relative workspaces).
    func isProjectFolderGrant(_ ws: StudyWorkspace) -> Bool {
        guard !ws.isDefault else { return false }
        if let rel = ws.relativePath, !rel.isEmpty { return false }
        if let id = UserDefaults.standard.string(forKey: Self.projectFolderWorkspaceIDKey),
           id == ws.id {
            return true
        }
        if ws.rootBookmarkData != nil, let abs = ws.absoluteRootPath, !abs.isEmpty {
            return !Self.isAppInternalPath(abs)
        }
        if let abs = ws.absoluteRootPath, !abs.isEmpty {
            return !Self.isAppInternalPath(abs)
        }
        return false
    }

    private static func isAppInternalPath(_ path: String) -> Bool {
        let p = normalizedPath(path)
        let connects = normalizedPath(ConnectsPaths.connectsRootURL.path)
        let study = normalizedPath(ConnectsPaths.studyRootURL.path)
        return p == connects || p.hasPrefix(connects + "/")
            || p == study || p.hasPrefix(study + "/")
    }

    /// User has already granted at least one project folder.
    func hasUsableFolderGrant() -> Bool {
        if let id = UserDefaults.standard.string(forKey: Self.projectFolderWorkspaceIDKey),
           let ws = workspace(id: id), isProjectFolderGrant(ws) {
            return true
        }
        if UserDefaults.standard.bool(forKey: Self.projectFolderGrantFlagKey),
           primaryGrantedWorkspace() != nil {
            return true
        }
        return primaryGrantedWorkspace() != nil
    }

    /// Best display label for the active project-folder grant (e.g. `Workspace`).
    func primaryGrantedFolderLabel() -> String? {
        guard let ws = primaryGrantedWorkspace() else { return nil }
        if let abs = ws.absoluteRootPath, !abs.isEmpty {
            return "\(ws.title) — \(abs)"
        }
        return ws.title
    }

    func primaryGrantedWorkspace() -> StudyWorkspace? {
        if let id = UserDefaults.standard.string(forKey: Self.projectFolderWorkspaceIDKey),
           let ws = workspace(id: id), isProjectFolderGrant(ws) {
            return ws
        }
        let granted = workspaces.filter { isProjectFolderGrant($0) }
        return granted.sorted { a, b in
            let ab = a.rootBookmarkData != nil
            let bb = b.rootBookmarkData != nil
            if ab != bb { return ab && !bb }
            let ap = a.absoluteRootPath?.count ?? Int.max
            let bp = b.absoluteRootPath?.count ?? Int.max
            return ap < bp
        }.first
    }

    static func normalizedPath(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        if p.hasPrefix("/private/") {
            p = String(p.dropFirst("/private".count))
        }
        return p
    }

    /// Bookmarked grant whose root contains `path` (prefer widest / shortest root).
    func bookmarkedWorkspaceCovering(path: String) -> StudyWorkspace? {
        let file = Self.normalizedPath(path)
        var best: StudyWorkspace?
        var bestLen = Int.max
        for ws in workspaces where !ws.isDefault {
            guard ws.rootBookmarkData != nil else { continue }
            let rootPath: String? = {
                if let abs = ws.absoluteRootPath, !abs.isEmpty {
                    return Self.normalizedPath(abs)
                }
                if let url = try? folderURL(for: ws.id) {
                    return Self.normalizedPath(url.path)
                }
                return nil
            }()
            guard let rp = rootPath else { continue }
            guard file == rp || file.hasPrefix(rp + "/") else { continue }
            guard rp.count < bestLen else { continue }
            best = ws
            bestLen = rp.count
        }
        return best
    }

    /// True when the chosen folder is so broad that a tree walk would hang (e.g. iCloud Drive root).
    static func isOverlyBroadFolder(_ url: URL) -> Bool {
        let path = Self.normalizedPath(url.path)
        if path.hasSuffix("/com~apple~CloudDocs") || path.hasSuffix("/Mobile Documents") {
            return true
        }
        let name = url.lastPathComponent
        return name.caseInsensitiveCompare("iCloud Drive") == .orderedSame
    }

    /// True when we can actually enumerate more than a trivial empty/failure result.
    func canListSiblings(in workspaceID: String) -> Bool {
        listFileNames(in: workspaceID).count > 1
    }

    /// True when the OS lets us list the workspace folder (even if it only has one study file).
    func hasDirectoryListingAccess(in workspaceID: String) -> Bool {
        guard let folder = try? folderURL(for: workspaceID) else { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
    }

    /// Prefer a previously granted directory-scoped workspace that covers this file path.
    /// Always prefer the **widest** covering root (shortest path): `Workspace/` over `DSP(NJU)/`.
    func workspaceWithDirectoryAccess(coveringFilePath path: String) -> StudyWorkspace? {
        if let grant = bookmarkedWorkspaceCovering(path: path) {
            return grant
        }
        let file = Self.normalizedPath(path)
        var bestAny: StudyWorkspace?
        var bestAnyLen = Int.max
        for ws in workspaces where !ws.isDefault {
            guard let abs = ws.absoluteRootPath, !abs.isEmpty else { continue }
            let rootPath = Self.normalizedPath(abs)
            let ok = file == rootPath || file.hasPrefix(rootPath + "/")
            // Widest grant = shortest root path.
            guard ok, rootPath.count < bestAnyLen else { continue }
            bestAny = ws
            bestAnyLen = rootPath.count
        }
        return bestAny
    }

    /// Open a file → reuse bookmarked grant when possible; never create DSP(NJU)-style leaf workspaces over it.
    /// Used for **security scope** only — conversation identity uses `conversationWorkspace(forFileAt:)`.
    @discardableResult
    func bindFolderAroundOpenFile(_ fileURL: URL) throws -> StudyWorkspace {
        let fileAccess = fileURL.startAccessingSecurityScopedResource()
        defer { if fileAccess { fileURL.stopAccessingSecurityScopedResource() } }

        if let existing = workspaceWithDirectoryAccess(coveringFilePath: fileURL.path),
           existing.rootBookmarkData != nil {
            _ = try? folderURL(for: existing.id)
            return existing
        }
        if let grant = bookmarkedWorkspaceCovering(path: fileURL.path) {
            _ = try? folderURL(for: grant.id)
            return grant
        }

        var folder = fileURL.deletingLastPathComponent().standardizedFileURL
        if let parent = try? fileURL.resourceValues(forKeys: [.parentDirectoryURLKey]).parentDirectory {
            folder = parent.standardizedFileURL
        }
        return try openFolderWorkspace(url: folder)
    }

    /// Parent directory path of a study document (normalized), if known.
    func parentFolderPath(ofDocumentID documentID: String) -> String? {
        if let path = StudyDocumentStore.shared.document(id: documentID)?.displayPath, !path.isEmpty {
            return Self.normalizedPath(
                URL(fileURLWithPath: path).deletingLastPathComponent().path
            )
        }
        if let url = try? StudyDocumentStore.shared.resolvedURL(forID: documentID) {
            return Self.normalizedPath(url.deletingLastPathComponent().path)
        }
        return nil
    }

    /// Workspace record whose root is exactly `path` (not a covering grant ancestor).
    func workspaceID(withExactRootPath path: String) -> String? {
        let target = Self.normalizedPath(path)
        return workspaces.first(where: { ws in
            guard !ws.isDefault else { return false }
            if let abs = ws.absoluteRootPath, !abs.isEmpty {
                return Self.normalizedPath(abs) == target
            }
            if let rel = ws.relativePath, !rel.isEmpty {
                let url = ConnectsPaths.documentsURL.appendingPathComponent(rel, isDirectory: true)
                return Self.normalizedPath(url.path) == target
            }
            return false
        })?.id
    }

    /// Conversation / history identity for an open file = its **immediate parent folder**.
    /// Never collapses to the project-folder grant (e.g. whole `Workspace/`).
    @discardableResult
    func conversationWorkspace(forFileAt fileURL: URL) -> StudyWorkspace {
        var folder = fileURL.deletingLastPathComponent().standardizedFileURL
        if let parent = try? fileURL.resourceValues(forKeys: [.parentDirectoryURLKey]).parentDirectory {
            folder = parent.standardizedFileURL
        }
        return ensureExactFolderWorkspace(at: folder)
    }

    /// Find or create a workspace row for this exact folder path (no grant steal).
    @discardableResult
    func ensureExactFolderWorkspace(at folderURL: URL) -> StudyWorkspace {
        let openedPath = Self.normalizedPath(folderURL.path)
        if let existingID = workspaceID(withExactRootPath: openedPath),
           let existing = workspace(id: existingID) {
            return existing
        }
        let created = StudyWorkspace(
            id: UUID().uuidString,
            title: folderURL.lastPathComponent.isEmpty ? "文件夹" : folderURL.lastPathComponent,
            isDefault: false,
            rootBookmarkData: nil,
            relativePath: nil,
            absoluteRootPath: openedPath,
            documentIDs: [],
            lastOpenedDocumentID: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        workspaces.insert(created, at: 0)
        save()
        notify()
        return created
    }

    func addDocument(_ documentID: String, to workspaceID: String) {
        guard var ws = workspace(id: workspaceID) else { return }
        if !ws.documentIDs.contains(documentID) {
            ws.documentIDs.append(documentID)
            ws.updatedAt = Date()
            replace(ws)
        }
    }

    /// Folder-level recent file pointer (workspace chat identity stays on the folder).
    func setLastOpenedDocument(_ documentID: String, in workspaceID: String) {
        guard var ws = workspace(id: workspaceID) else { return }
        var changed = false
        if !ws.documentIDs.contains(documentID) {
            ws.documentIDs.append(documentID)
            changed = true
        }
        if ws.lastOpenedDocumentID != documentID {
            ws.lastOpenedDocumentID = documentID
            changed = true
        }
        guard changed else { return }
        ws.updatedAt = Date()
        replace(ws)
    }

    func clearLastOpenedDocument(in workspaceID: String) {
        guard var ws = workspace(id: workspaceID), ws.lastOpenedDocumentID != nil else { return }
        ws.lastOpenedDocumentID = nil
        ws.updatedAt = Date()
        replace(ws)
    }

    /// Validated last-opened document still living under this folder; clears stale ids.
    func lastOpenedDocumentID(in workspaceID: String) -> String? {
        guard var ws = workspace(id: workspaceID),
              let docID = ws.lastOpenedDocumentID else { return nil }
        if containsDocument(docID, in: workspaceID) {
            return docID
        }
        // Stale pointer — also accept path parent match when not yet in documentIDs.
        if let parent = parentFolderPath(ofDocumentID: docID),
           let root = (try? folderURL(for: workspaceID)).map({ Self.normalizedPath($0.path) }),
           parent == root {
            if !ws.documentIDs.contains(docID) {
                ws.documentIDs.append(docID)
                ws.updatedAt = Date()
                replace(ws)
            }
            return docID
        }
        ws.lastOpenedDocumentID = nil
        ws.updatedAt = Date()
        replace(ws)
        return nil
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
            var mutated = false
            if workspaces[i].documentIDs.contains(documentID) {
                workspaces[i].documentIDs.removeAll { $0 == documentID }
                mutated = true
            }
            if workspaces[i].lastOpenedDocumentID == documentID {
                workspaces[i].lastOpenedDocumentID = nil
                mutated = true
            }
            if mutated {
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
    /// `rawName` may be a workspace-relative path (`Code/a.v`); `.`/`..` segments rejected.
    @discardableResult
    func createFile(named rawName: String, content: String, in workspaceID: String) throws -> StudyDocument {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = name.split(separator: "/").map(String.init)
        guard !name.isEmpty, !segments.isEmpty,
              segments.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw StudyWorkspaceError.invalidName
        }
        let leaf = segments.last ?? name
        if !leaf.contains(".") {
            name += ".md"
        }
        // Prefer creating directly under the workspace folder (security-scoped when granted).
        let folder = try folderURL(for: workspaceID)
        if let grant = workspaceWithDirectoryAccess(coveringFilePath: folder.path)
            ?? primaryGrantedWorkspace() {
            _ = try? folderURL(for: grant.id)
        }
        let dest = Self.absoluteURL(relativePath: name, under: folder)
        let stdDest = (dest.path as NSString).standardizingPath
        let stdRoot = (folder.path as NSString).standardizingPath
        guard stdDest.hasPrefix(stdRoot + "/") else { throw StudyWorkspaceError.invalidName }
        if FileManager.default.fileExists(atPath: dest.path) {
            throw StudyWorkspaceError.fileExists
        }
        guard let data = content.data(using: .utf8) else {
            throw StudyWorkspaceError.writeFailed
        }
        do {
            let parent = dest.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
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

    /// Light refresh only: drop ghost IDs whose files vanished under this folder.
    /// Never walks the whole tree / never bulk-registers — that froze the app on iCloud Drive.
    @discardableResult
    func scanAndSyncDocuments(workspaceID: String, preferredFolderURL: URL? = nil) throws -> [StudyDocument] {
        let folder: URL
        if let preferredFolderURL {
            folder = preferredFolderURL
            _ = try? folderURL(for: workspaceID)
        } else {
            folder = try folderURL(for: workspaceID)
        }
        let root = (folder.path as NSString).standardizingPath
        guard var ws = workspace(id: workspaceID) else { throw StudyWorkspaceError.notFound }

        let liveIDs = ws.documentIDs.filter { id in
            guard let path = StudyDocumentStore.shared.document(id: id)?.displayPath,
                  !path.isEmpty else { return false }
            let file = (path as NSString).standardizingPath
            guard file == root || file.hasPrefix(root + "/") else { return false }
            return FileManager.default.fileExists(atPath: path)
        }
        if liveIDs != ws.documentIDs {
            ws.documentIDs = liveIDs
            ws.updatedAt = Date()
            replace(ws)
        }
        return []
    }

    /// Prefer an existing workspace whose folder already contains this path.
    func workspaceContaining(filePath: String) -> StudyWorkspace? {
        let file = (filePath as NSString).standardizingPath
        // Prefer the deepest (longest root) match so nested workspaces win.
        var best: StudyWorkspace?
        var bestLen = -1
        for ws in workspaces {
            guard let folder = try? folderURL(for: ws.id) else { continue }
            let root = (folder.path as NSString).standardizingPath
            let ok = (file == root) || file.hasPrefix(root + "/")
            guard ok, root.count > bestLen else { continue }
            best = ws
            bestLen = root.count
        }
        return best
    }

    /// First real file in the folder after sync (sorted by relative path). Nil if empty.
    func primaryDocumentID(in workspaceID: String) -> String? {
        workspace(id: workspaceID)?.documentIDs.first
    }

    /// True when `documentID` is registered and its path still lives under the workspace folder.
    func containsDocument(_ documentID: String, in workspaceID: String) -> Bool {
        guard let ws = workspace(id: workspaceID),
              ws.documentIDs.contains(documentID),
              let path = StudyDocumentStore.shared.document(id: documentID)?.displayPath,
              let folder = try? folderURL(for: workspaceID) else { return false }
        let file = (path as NSString).standardizingPath
        let root = (folder.path as NSString).standardizingPath
        return file == root || file.hasPrefix(root + "/")
    }

    /// Relative paths of study-openable files under the folder (recursive), sorted.
    /// Example: `Code/async_fifo.v`, `Gowin/FPGA/foo.pdf`.
    func listFileNames(in workspaceID: String) -> [String] {
        guard let folder = try? folderURL(for: workspaceID) else { return [] }
        return listStudyFileURLs(in: workspaceID).map { Self.displayName(of: $0, under: folder) }
    }

    /// Names for the Study title / options switcher.
    /// Names for the Study title / options switcher — same-directory leaf names only.
    func listSwitcherFileNames(ofDocumentID documentID: String?, in workspaceID: String) -> [String] {
        guard let documentID else { return [] }
        return listSiblingFileNames(ofDocumentID: documentID, in: workspaceID)
    }

    private static func uniqueLeafNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in names {
            let leaf = (raw as NSString).lastPathComponent
            guard seen.insert(leaf).inserted else { continue }
            out.append(leaf)
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Disk walk from a file → project/git root (or parent). Never filters away found URLs.
    private static func listStudyRelativePaths(nearFile fileURL: URL) -> [String] {
        let root = suggestedWorkspaceRoot(forFile: fileURL)
        let found = enumerateStudyFiles(under: root)
        if !found.isEmpty {
            return found.map { displayName(of: $0, under: root) }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        let parent = fileURL.deletingLastPathComponent()
        let sibs = enumerateStudyFilesInDirectory(parent)
        if !sibs.isEmpty {
            return sibs.map { displayName(of: $0, under: root) }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        // Last resort: path-string directory listing (bypasses URL resource-value quirks).
        if let items = try? FileManager.default.contentsOfDirectory(atPath: parent.path) {
            let filtered = items.filter { name in
                let ext = (name as NSString).pathExtension
                return StudyDocument.kind(forExtension: ext) != nil
            }
            if !filtered.isEmpty {
                return filtered.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            }
        }
        return [fileURL.lastPathComponent]
    }

    private static func displayName(of url: URL, under root: URL) -> String {
        if let rel = relativePath(of: url, under: root) { return rel }
        let base = (root.path as NSString).standardizingPath
        let file = (url.path as NSString).standardizingPath
        if file.hasPrefix(base + "/") {
            return String(file.dropFirst(base.count + 1))
        }
        return url.lastPathComponent
    }

    /// Same-folder sibling **leaf names**. Falls back to opened docs if disk listing fails.
    func listSiblingFileNames(ofDocumentID documentID: String, in workspaceID: String) -> [String] {
        if let disk = listSiblingFileNamesFromDisk(ofDocumentID: documentID, in: workspaceID) {
            return disk
        }
        return fallbackOpenedLeafNames(documentID: documentID, workspaceID: workspaceID)
    }

    /// Disk listing of same-folder study files. `nil` = enumeration failed.
    /// Always lists the **current file's parent directory**. Project-folder grant is only
    /// warmed for security scope — never used as the listing root identity.
    func listSiblingFileNamesFromDisk(ofDocumentID documentID: String, in workspaceID: String) -> [String]? {
        let fileURL: URL? = {
            if let path = StudyDocumentStore.shared.document(id: documentID)?.displayPath,
               !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
            if let resolved = try? StudyDocumentStore.shared.resolvedURL(forID: documentID) {
                return resolved
            }
            return nil
        }()
        guard let fileURL else { return nil }

        // Warm grant scope if it covers this file (authorization only).
        if let grantID = workspaceWithDirectoryAccess(coveringFilePath: fileURL.path)?.id
            ?? primaryGrantedWorkspace()?.id {
            _ = try? folderURL(for: grantID)
        } else {
            _ = try? folderURL(for: workspaceID)
        }

        let fileAccess = fileURL.startAccessingSecurityScopedResource()
        defer { if fileAccess { fileURL.stopAccessingSecurityScopedResource() } }

        let parent = fileURL.deletingLastPathComponent()
        if Self.isAppInternalPath(parent.path) {
            return nil
        }

        // Prefer listing via grant-derived parent URL when the file sits under a grant
        // (keeps security scope on iOS); otherwise list the raw parent path.
        var parents: [URL] = [parent]
        if let grant = workspaceWithDirectoryAccess(coveringFilePath: fileURL.path)
            ?? primaryGrantedWorkspace(),
           let root = try? folderURL(for: grant.id),
           let scoped = Self.parentDirectoryURL(of: fileURL, underGrantedRoot: root) {
            parents.insert(scoped, at: 0)
        }

        for dir in parents {
            if let names = Self.shallowStudyFileNamesViaURL(in: dir) {
                return Self.nonEmptyDiskNames(names, currentFile: fileURL)
            }
            var coordinated: [String]?
            var coordError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: dir, options: [], error: &coordError) { url in
                coordinated = Self.shallowStudyFileNamesViaURL(in: url)
                    ?? Self.shallowStudyFileNames(in: url)
            }
            if let names = coordinated {
                return Self.nonEmptyDiskNames(names, currentFile: fileURL)
            }
            if let names = Self.shallowStudyFileNames(in: dir) {
                return Self.nonEmptyDiskNames(names, currentFile: fileURL)
            }
        }
        return nil
    }

    /// Empty folder: only keep the current leaf if it still exists on disk.
    private static func nonEmptyDiskNames(_ names: [String], currentFile: URL) -> [String] {
        if !names.isEmpty { return names }
        return FileManager.default.fileExists(atPath: currentFile.path)
            ? [currentFile.lastPathComponent]
            : []
    }

    /// Parent of `fileURL` as a URL still under the granted root (scope-preserving).
    private static func parentDirectoryURL(of fileURL: URL, underGrantedRoot root: URL) -> URL? {
        if let rel = relativePath(of: fileURL, under: root) {
            let parentRel = (rel as NSString).deletingLastPathComponent
            if parentRel.isEmpty || parentRel == "." { return root }
            return absoluteURL(relativePath: parentRel, under: root)
        }
        let rootPath = (root.resolvingSymlinksInPath().path as NSString).standardizingPath
        let filePath = (fileURL.resolvingSymlinksInPath().path as NSString).standardizingPath
        let rootAlt = stripPrivatePrefix(rootPath)
        let fileAlt = stripPrivatePrefix(filePath)
        for (rp, fp) in [(rootPath, filePath), (rootAlt, fileAlt), (rootPath, fileAlt), (rootAlt, filePath)] {
            guard fp.hasPrefix(rp + "/") else { continue }
            let parentPath = (fp as NSString).deletingLastPathComponent
            let parentRel = String(parentPath.dropFirst(rp.count + 1))
            if parentRel.isEmpty { return root }
            return absoluteURL(relativePath: parentRel, under: root)
        }
        return nil
    }

    private static func stripPrivatePrefix(_ path: String) -> String {
        if path.hasPrefix("/private/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    private func fallbackOpenedLeafNames(documentID: String, workspaceID: String) -> [String] {
        // Only siblings that share the *current file's parent* — never dump the whole grant/workspace.
        _ = workspaceID
        let currentParent: String? = {
            guard let path = StudyDocumentStore.shared.document(id: documentID)?.displayPath,
                  !path.isEmpty else { return nil }
            return Self.normalizedPath(URL(fileURLWithPath: path).deletingLastPathComponent().path)
        }()

        var names: [String] = []
        var seen = Set<String>()
        let consider: (String) -> Void = { path in
            let url = URL(fileURLWithPath: path)
            let parent = Self.normalizedPath(url.deletingLastPathComponent().path)
            if let currentParent, parent != currentParent { return }
            let leaf = url.lastPathComponent
            if seen.insert(leaf).inserted { names.append(leaf) }
        }

        if let path = StudyDocumentStore.shared.document(id: documentID)?.displayPath {
            consider(path)
        }
        for doc in StudyDocumentStore.shared.recentDocuments(limit: 200) {
            guard let path = doc.displayPath, !path.isEmpty else { continue }
            consider(path)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Path-string listing (may fail under sandbox even when URL listing works).
    private static func shallowStudyFileNames(in directory: URL) -> [String]? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: directory.path) else { return nil }
        let filtered = items.filter { name in
            if name.hasPrefix(".") { return false }
            let ext = (name as NSString).pathExtension
            return StudyDocument.kind(forExtension: ext) != nil
        }
        guard !filtered.isEmpty else { return [] }
        return filtered.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// URL-based listing from a security-scoped directory URL (no isRegularFile filter).
    private static func shallowStudyFileNamesViaURL(in directory: URL) -> [String]? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var names: [String] = []
        for url in items {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }
            let ext = url.pathExtension
            guard StudyDocument.kind(forExtension: ext) != nil else { continue }
            names.append(url.lastPathComponent)
        }
        guard !names.isEmpty else { return [] }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Absolute file URL for a workspace-relative path (`Code/a.v` or `a.v`).
    func fileURL(relativePath: String, in workspaceID: String) throws -> URL {
        let folder = try folderURL(for: workspaceID)
        return Self.absoluteURL(relativePath: relativePath, under: folder)
    }

    /// Resolve a menu name (leaf or relative path) to a real on-disk URL.
    /// Prefers already-registered displayPaths so we don't invent `Connects/spi_master.v`
    /// when the real file lives under an external project folder.
    func resolveOpenableFileURL(
        named name: String,
        in workspaceID: String,
        nearDocumentID: String? = nil
    ) throws -> URL {
        let leaf = (name as NSString).lastPathComponent
        let normalizedName = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // 1) Exact / suffix match against registered docs in this workspace.
        if let ws = workspace(id: workspaceID) {
            for id in ws.documentIDs {
                guard let path = StudyDocumentStore.shared.document(id: id)?.displayPath,
                      !path.isEmpty else { continue }
                let fileURL = URL(fileURLWithPath: path)
                let pathNorm = Self.normalizedPath(path)
                if pathNorm.hasSuffix("/" + Self.normalizedPath(normalizedName))
                    || pathNorm == Self.normalizedPath(normalizedName)
                    || fileURL.lastPathComponent.compare(leaf, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                    if FileManager.default.fileExists(atPath: path) {
                        // For leaf-only names, prefer the file in the same folder as the current doc.
                        if !normalizedName.contains("/"),
                           let nearID = nearDocumentID,
                           let nearPath = StudyDocumentStore.shared.document(id: nearID)?.displayPath {
                            let nearParent = Self.normalizedPath(
                                URL(fileURLWithPath: nearPath).deletingLastPathComponent().path
                            )
                            let candidateParent = Self.normalizedPath(fileURL.deletingLastPathComponent().path)
                            if nearParent == candidateParent {
                                return fileURL
                            }
                            // Keep looking for a same-folder match; remember first hit as fallback.
                            continue
                        }
                        return fileURL
                    }
                }
            }
            // Second pass: leaf match anywhere in workspace (after same-folder preference failed).
            if !normalizedName.contains("/") {
                for id in ws.documentIDs {
                    guard let path = StudyDocumentStore.shared.document(id: id)?.displayPath,
                          !path.isEmpty else { continue }
                    let fileURL = URL(fileURLWithPath: path)
                    if fileURL.lastPathComponent.compare(leaf, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame,
                       FileManager.default.fileExists(atPath: path) {
                        return fileURL
                    }
                }
            }
        }

        // 2) Global registry: relative path or unique leaf.
        var leafHits: [URL] = []
        for doc in StudyDocumentStore.shared.recentDocuments(limit: 400) {
            guard let path = doc.displayPath, !path.isEmpty else { continue }
            let fileURL = URL(fileURLWithPath: path)
            let pathNorm = Self.normalizedPath(path)
            if pathNorm.hasSuffix("/" + Self.normalizedPath(normalizedName))
                || pathNorm == Self.normalizedPath(normalizedName) {
                if FileManager.default.fileExists(atPath: path) { return fileURL }
            }
            if fileURL.lastPathComponent.compare(leaf, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame,
               FileManager.default.fileExists(atPath: path) {
                leafHits.append(fileURL)
            }
        }
        if normalizedName.contains("/"), let hit = leafHits.first(where: {
            Self.normalizedPath($0.path).hasSuffix("/" + Self.normalizedPath(normalizedName))
        }) {
            return hit
        }

        // 3) Build path candidates from workspace root + current file parent.
        var candidates: [URL] = []
        let root = try? folderURL(for: workspaceID)
        if let root {
            candidates.append(Self.absoluteURL(relativePath: normalizedName, under: root))
            if !normalizedName.contains("/") {
                candidates.append(root.appendingPathComponent(leaf))
            }
        }
        if let nearID = nearDocumentID {
            let nearURL: URL? = {
                if let path = StudyDocumentStore.shared.document(id: nearID)?.displayPath, !path.isEmpty {
                    return URL(fileURLWithPath: path)
                }
                return try? StudyDocumentStore.shared.resolvedURL(forID: nearID)
            }()
            if let nearURL {
                candidates.append(nearURL.deletingLastPathComponent().appendingPathComponent(leaf))
                if let root,
                   let rel = Self.relativePath(of: nearURL, under: root) {
                    let parentRel = (rel as NSString).deletingLastPathComponent
                    let combined = (parentRel.isEmpty || parentRel == ".")
                        ? leaf
                        : (parentRel as NSString).appendingPathComponent(leaf)
                    candidates.append(Self.absoluteURL(relativePath: combined, under: root))
                }
            }
        }
        // Same-folder leaf preference among global hits.
        if let nearID = nearDocumentID,
           let nearPath = StudyDocumentStore.shared.document(id: nearID)?.displayPath {
            let nearParent = Self.normalizedPath(
                URL(fileURLWithPath: nearPath).deletingLastPathComponent().path
            )
            if let sameFolder = leafHits.first(where: {
                Self.normalizedPath($0.deletingLastPathComponent().path) == nearParent
            }) {
                return sameFolder
            }
        }
        if leafHits.count == 1 { return leafHits[0] }

        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        throw StudyWorkspaceError.notFound
    }

    /// Relative path of a document inside the workspace, if it lives there.
    func relativePath(ofDocumentID documentID: String, in workspaceID: String) -> String? {
        guard let path = StudyDocumentStore.shared.document(id: documentID)?.displayPath,
              let folder = try? folderURL(for: workspaceID) else { return nil }
        return Self.relativePath(of: URL(fileURLWithPath: path), under: folder)
    }

    /// True when the folder has no study-openable files on disk (ignore registration state).
    /// Shallow top-level only — never deep-walk (iCloud Drive roots).
    func isFolderEmptyOfStudyFiles(_ workspaceID: String) -> Bool {
        if let ws = workspace(id: workspaceID), !ws.documentIDs.isEmpty { return false }
        guard let folder = try? folderURL(for: workspaceID) else { return true }
        return Self.enumerateStudyFilesInDirectory(folder).isEmpty
    }

    private func listStudyFileURLs(in workspaceID: String) -> [URL] {
        guard let folder = try? folderURL(for: workspaceID) else { return [] }
        return Self.enumerateStudyFiles(under: folder)
    }

    /// When opening a file, prefer the git/project root so sibling folders (e.g. `Gowin/*.pdf`)
    /// appear in the options menu — not just the immediate parent like `Code/`.
    static func suggestedWorkspaceRoot(forFile fileURL: URL) -> URL {
        let dir = fileURL.deletingLastPathComponent().standardizedFileURL
        var current = dir
        for _ in 0..<10 {
            let git = current.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir) {
                return current
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path || parent.path == "/" { break }
            current = parent
        }
        return dir
    }

    private static let skipDirectoryNames: Set<String> = [
        ".git", ".workspace", ".cursor", ".vscode", ".idea",
        "node_modules", "DerivedData", "build", ".build",
        "Pods", "__pycache__", ".swiftpm", ".trash", "xcuserdata",
        "Library", "Applications", "Downloads", ".Trash"
    ]

    /// Non-recursive: study-openable files directly inside `directory`.
    private static func enumerateStudyFilesInDirectory(_ directory: URL) -> [URL] {
        // Path-based names first (iCloud-friendly); avoid isRegularFile filters that hide placeholders.
        if let names = shallowStudyFileNames(in: directory) {
            return names.map { directory.appendingPathComponent($0) }
        }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var results: [URL] = []
        for url in items {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true { continue }
            let ext = url.pathExtension.lowercased()
            guard StudyDocument.kind(forExtension: ext) != nil else { continue }
            results.append(url)
        }
        return results.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// Bounded recursive collect. Never uses `subpathsOfDirectory` (that freezes on iCloud Drive).
    private static func enumerateStudyFiles(under root: URL, maxDepth: Int = 3, maxFiles: Int = 80) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if skipDirectoryNames.contains(url.lastPathComponent) || enumerator.level >= maxDepth {
                    enumerator.skipDescendants()
                }
                continue
            }
            if values?.isRegularFile == false { continue }
            let ext = url.pathExtension.lowercased()
            guard StudyDocument.kind(forExtension: ext) != nil else { continue }
            results.append(url)
            if results.count >= maxFiles {
                break
            }
        }
        return results.sorted {
            let a = relativePath(of: $0, under: root) ?? $0.lastPathComponent
            let b = relativePath(of: $1, under: root) ?? $1.lastPathComponent
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    static func relativePath(of url: URL, under root: URL) -> String? {
        let strip: (String) -> String = { path in
            var p = (path as NSString).standardizingPath
            if p.hasPrefix("/private/") {
                p = String(p.dropFirst("/private".count))
            }
            return p
        }
        let candidates: [(String, String)] = [
            (
                strip(url.resolvingSymlinksInPath().path),
                strip(root.resolvingSymlinksInPath().path)
            ),
            (
                strip(url.standardizedFileURL.path),
                strip(root.standardizedFileURL.path)
            ),
            (
                strip(url.path),
                strip(root.path)
            )
        ]
        for (file, base) in candidates {
            if file.hasPrefix(base + "/") {
                return String(file.dropFirst(base.count + 1))
            }
            if file == base {
                return url.lastPathComponent
            }
        }
        return nil
    }

    private static func absoluteURL(relativePath: String, under root: URL) -> URL {
        // `.` / `..` must never escape the workspace root.
        let parts = relativePath.split(separator: "/").map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }

    /// Rename (including changing extension) a file inside the workspace folder.
    /// `oldName` may be a relative path (`Code/a.v`). New name stays in the same directory.
    @discardableResult
    func renameFile(from oldName: String, to rawNewName: String, in workspaceID: String) throws -> StudyDocument {
        var newLeaf = rawNewName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newLeaf.isEmpty, !newLeaf.contains("/"), newLeaf != "." , newLeaf != ".." else {
            throw StudyWorkspaceError.invalidName
        }
        if !newLeaf.contains(".") {
            let oldExt = (oldName as NSString).pathExtension
            if !oldExt.isEmpty { newLeaf += ".\(oldExt)" }
            else { newLeaf += ".txt" }
        }
        let folder = try folderURL(for: workspaceID)
        let src = Self.absoluteURL(relativePath: oldName, under: folder)
        let dest = src.deletingLastPathComponent().appendingPathComponent(newLeaf)
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

    /// Undo of an agent-created file: remove the on-disk file + registry rows
    /// for a registered workspace document.
    func deleteDocumentFile(documentID: String, in workspaceID: String) {
        guard let doc = StudyDocumentStore.shared.document(id: documentID) else { return }
        if let abs = doc.displayPath, !abs.isEmpty {
            try? FileManager.default.removeItem(atPath: abs)
        }
        removeDocument(documentID, from: workspaceID)
        StudyDocumentStore.shared.delete(documentID: documentID)
    }

    /// Delete a file from the workspace folder and detach its StudyDocument.
    /// `name` may be a relative path (`Gowin/FPGA/a.pdf`).
    func deleteFile(named name: String, in workspaceID: String) throws {
        let folder = try folderURL(for: workspaceID)
        let url = Self.absoluteURL(relativePath: name, under: folder)
        let path = url.path
        // Containment: deletes must never leave the workspace root.
        let std = (path as NSString).standardizingPath
        let root = (folder.path as NSString).standardizingPath
        guard std.hasPrefix(root + "/") else { throw StudyWorkspaceError.invalidName }
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
        // Migrate: remember an external project grant if one exists.
        if UserDefaults.standard.string(forKey: Self.projectFolderWorkspaceIDKey) == nil,
           let grant = workspaces.first(where: { isProjectFolderGrant($0) }) {
            markAsProjectFolderGrant(grant.id)
        }
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
