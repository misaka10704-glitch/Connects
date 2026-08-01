import UIKit
import UniformTypeIdentifiers

/// Study file browser: system **New File** + open a file inside an already-granted project folder.
/// First-time project access is a separate folder picker (large-folder grant + bookmark).
final class StudyFilesBrowserController: UIDocumentBrowserViewController, UIDocumentBrowserViewControllerDelegate {
    var onPick: ((URL) -> Void)?

    static func make() -> StudyFilesBrowserController {
        let browser: StudyFilesBrowserController
        if #available(iOS 14.0, *) {
            var types: [UTType] = [.item, .data, .content, .pdf, .plainText, .text, .sourceCode]
            if let md = UTType("net.daringfireball.markdown") { types.append(md) }
            if let md2 = UTType("public.markdown") { types.append(md2) }
            browser = StudyFilesBrowserController(forOpening: types)
        } else {
            browser = StudyFilesBrowserController(forOpeningFilesWithContentTypes: [
                "public.item",
                "public.data",
                "public.content",
                "com.adobe.pdf",
                "public.plain-text",
                "public.text",
                "public.source-code",
                "net.daringfireball.markdown",
                "public.markdown"
            ])
        }
        browser.delegate = browser
        browser.allowsDocumentCreation = true
        browser.allowsPickingMultipleItems = false
        browser.shouldShowFileExtensions = true
        browser.localizedCreateDocumentActionTitle = "New File"
        return browser
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let cancel = UIBarButtonItem(
            title: "取消",
            style: .plain,
            target: self,
            action: #selector(cancelTapped)
        )
        additionalTrailingNavigationBarButtonItems = [cancel]
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    private func finish(with url: URL) {
        dismiss(animated: true) { [weak self] in
            self?.onPick?(url)
        }
    }

    private func isDirectoryURL(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true { return true }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            return isDir.boolValue
        }
        return false
    }

    // MARK: - UIDocumentBrowserViewControllerDelegate

    func documentBrowser(_ controller: UIDocumentBrowserViewController,
                         didPickDocumentsAt documentURLs: [URL]) {
        guard let url = documentURLs.first else { return }
        let accessing = url.startAccessingSecurityScopedResource()

        if isDirectoryURL(url) {
            _ = try? StudyWorkspaceStore.shared.openFolderWorkspace(url: url, asProjectGrant: true)
            if accessing { url.stopAccessingSecurityScopedResource() }
            finish(with: url)
            return
        }

        if let existing = StudyWorkspaceStore.shared.workspaceWithDirectoryAccess(
            coveringFilePath: url.path
        ) {
            _ = try? StudyWorkspaceStore.shared.scanAndSyncDocuments(workspaceID: existing.id)
        } else {
            _ = try? StudyWorkspaceStore.shared.bindFolderAroundOpenFile(url)
        }
        if accessing { url.stopAccessingSecurityScopedResource() }
        finish(with: url)
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController,
                         didRequestDocumentCreationWithHandler importHandler: @escaping (URL?, UIDocumentBrowserViewController.ImportMode) -> Void) {
        let alert = UIAlertController(
            title: "New File",
            message: "任意后缀，例如 notes.md / top.v / a.html",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "Untitled.md"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.text = "Untitled.md"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
            importHandler(nil, .none)
        })
        alert.addAction(UIAlertAction(title: "创建", style: .default) { _ in
            var name = alert.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if name.isEmpty { name = "Untitled.md" }
            if name.contains("/") || name == "." || name == ".." {
                importHandler(nil, .none)
                return
            }
            if !name.contains(".") { name += ".md" }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let fileURL = tmp.appendingPathComponent(name)
                try Data().write(to: fileURL, options: .atomic)
                importHandler(fileURL, .move)
            } catch {
                importHandler(nil, .none)
            }
        })
        present(alert, animated: true)
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController,
                         didImportDocumentAt sourceURL: URL,
                         toDestinationURL destinationURL: URL) {
        if let existing = StudyWorkspaceStore.shared.workspaceWithDirectoryAccess(
            coveringFilePath: destinationURL.path
        ) {
            _ = try? StudyWorkspaceStore.shared.scanAndSyncDocuments(workspaceID: existing.id)
        } else {
            let parent = destinationURL.deletingLastPathComponent()
            if (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) != nil {
                _ = try? StudyWorkspaceStore.shared.openFolderWorkspace(url: parent, asProjectGrant: true)
            } else {
                _ = try? StudyWorkspaceStore.shared.bindFolderAroundOpenFile(destinationURL)
            }
        }
        finish(with: destinationURL)
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController,
                         failedToImportDocumentAt documentURL: URL,
                         error: Error?) {
        let message = error?.localizedDescription ?? "无法创建或导入文件。"
        let alert = UIAlertController(title: "New File", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}
