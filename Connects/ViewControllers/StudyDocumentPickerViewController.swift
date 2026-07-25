import UIKit

protocol StudyDocumentPickerDelegate: AnyObject {
    func studyDocumentPicker(_ picker: StudyDocumentPickerViewController, didSelect documentID: String)
}

final class StudyDocumentPickerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate, UIGestureRecognizerDelegate {
    weak var delegate: StudyDocumentPickerDelegate?

    private enum ImportKind {
        case pdf
        case markdown
        case markdownImages
    }

    private let tableView = UITableView(frame: .zero, style: .grouped)
    private var documents: [StudyDocument] = []
    private var pendingImportKind: ImportKind = .pdf
    private var isImportingMarkdown = false
    private var pendingMarkdownURL: URL?
    private var pendingAccessRoot: URL?
    private var rowLongPress: UILongPressGestureRecognizer?
    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "选择文档"
        view.backgroundColor = DSTheme.c.background
        navigationItem.leftBarButtonItem = ActionIconFactory.barItem(
            kind: .chevronLeft,
            target: self,
            action: #selector(closeTapped),
            accessibility: "关闭"
        )

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = DSTheme.c.background
        tableView.separatorColor = DSTheme.c.border
        if #available(iOS 11.0, *) {
            tableView.dragInteractionEnabled = false
        }
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reload),
            name: .studyDocumentsDidUpdate,
            object: nil
        )
        installRowLongPressIfNeeded()
        reload()
    }

    private func installRowLongPressIfNeeded() {
        guard rowLongPress == nil else { return }
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        longPress.cancelsTouchesInView = false
        longPress.delegate = self
        tableView.addGestureRecognizer(longPress)
        rowLongPress = longPress
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === rowLongPress
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === rowLongPress && otherGestureRecognizer is UILongPressGestureRecognizer
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func closeTapped() {
        if let nav = navigationController, nav.viewControllers.first !== self {
            nav.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    @objc private func reload() {
        documents = StudyDocumentStore.shared.recentDocuments()
        tableView.reloadData()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        documents.count + 2
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "StudyDocCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "StudyDocCell")
        cell.backgroundColor = DSTheme.c.surface
        cell.textLabel?.font = DSTheme.bodyFont(size: 15)
        cell.textLabel?.textColor = DSTheme.c.textPrimary
        cell.detailTextLabel?.font = DSTheme.bodyFont(size: 12)
        cell.detailTextLabel?.textColor = DSTheme.c.textSecondary
        cell.accessoryType = .none
        if indexPath.row == 0 {
            cell.textLabel?.text = "从文件导入 PDF…"
            cell.detailTextLabel?.text = nil
            cell.imageView?.image = ActionIconFactory.image(.plus, pointSize: 16)
        } else if indexPath.row == 1 {
            cell.textLabel?.text = "从文件导入 Markdown…"
            cell.detailTextLabel?.text = "选 .md；有图再进 assets 全选（自动按引用甄别）"
            cell.imageView?.image = ActionIconFactory.image(.plus, pointSize: 16)
        } else {
            let doc = documents[indexPath.row - 2]
            cell.textLabel?.text = doc.title
            let size = byteFormatter.string(fromByteCount: doc.fileSize)
            let opened = dateFormatter.string(from: doc.lastOpenedAt)
            let kindLabel = doc.kind == .markdown ? "Markdown" : "PDF"
            cell.detailTextLabel?.text = "\(kindLabel) · \(size) · 最近打开 \(opened)"
            cell.imageView?.image = ActionIconFactory.image(.book, pointSize: 16)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.row == 0 {
            presentImportPicker(kind: .pdf)
            return
        }
        if indexPath.row == 1 {
            presentImportPicker(kind: .markdown)
            return
        }
        let doc = documents[indexPath.row - 2]
        delegate?.studyDocumentPicker(self, didSelect: doc.id)
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        documents.isEmpty ? nil : "向左滑动或长按文档可删除"
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        indexPath.row > 1
    }

    func tableView(
        _ tableView: UITableView,
        editActionsForRowAt indexPath: IndexPath
    ) -> [UITableViewRowAction]? {
        guard indexPath.row > 1 else { return nil }
        let doc = documents[indexPath.row - 2]
        let delete = UITableViewRowAction(style: .destructive, title: "删除") { [weak self] _, _ in
            self?.confirmDelete(document: doc)
        }
        return [delete]
    }

    func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, indexPath.row > 1 else { return }
        confirmDelete(document: documents[indexPath.row - 2])
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard indexPath.row > 1 else { return nil }
        let doc = documents[indexPath.row - 2]
        let delete = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            self?.confirmDelete(document: doc, completion: completion)
        }
        let config = UISwipeActionsConfiguration(actions: [delete])
        config.performsFirstActionWithFullSwipe = false
        return config
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: tableView)
        guard let indexPath = tableView.indexPathForRow(at: point), indexPath.row > 1 else { return }
        let doc = documents[indexPath.row - 2]
        tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
        ConnectsMenu.present(
            from: self,
            title: doc.title,
            items: [
                ConnectsMenuItem(title: "删除文档", icon: .trash, isDestructive: true) { [weak self] in
                    self?.confirmDelete(document: doc)
                }
            ],
            sourceView: tableView,
            sourceRect: CGRect(x: point.x, y: point.y, width: 1, height: 1)
        )
    }

    private func confirmDelete(document: StudyDocument, completion: ((Bool) -> Void)? = nil) {
        let alert = UIAlertController(
            title: "删除「\(document.title)」？",
            message: "文件与阅读进度将从本机移除；已依附此文档的对话会取消依附。删除后可重新导入同名文件。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
            completion?(false)
        })
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { _ in
            StudyDocumentStore.shared.delete(documentID: document.id)
            completion?(true)
        })
        present(alert, animated: true)
    }

    private func presentImportPicker(kind: ImportKind) {
        pendingImportKind = kind
        let types: [String]
        let mode: UIDocumentPickerMode
        let multi: Bool
        switch kind {
        case .pdf:
            types = ["com.adobe.pdf"]
            mode = .import
            multi = false
        case .markdown:
            types = [
                "net.daringfireball.markdown",
                "public.markdown",
                "public.plain-text",
                "public.text"
            ]
            mode = .open
            multi = false
        case .markdownImages:
            types = ["public.image", "public.png", "public.jpeg", "com.compuserve.gif", "public.tiff"]
            mode = .open
            multi = true
        }
        let picker = UIDocumentPickerViewController(documentTypes: types, in: mode)
        picker.delegate = self
        picker.allowsMultipleSelection = multi
        if let pop = picker.popoverPresentationController {
            let row = kind == .pdf ? 0 : 1
            pop.sourceView = tableView
            pop.sourceRect = tableView.rectForRow(at: IndexPath(row: row, section: 0))
        }
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch pendingImportKind {
        case .pdf:
            guard let url = urls.first else { return }
            do {
                let doc = try StudyDocumentStore.shared.importPDF(from: url)
                delegate?.studyDocumentPicker(self, didSelect: doc.id)
            } catch {
                presentImportError(error)
            }
        case .markdown:
            guard let url = urls.first else { return }
            handlePickedMarkdown(url)
        case .markdownImages:
            guard let md = pendingMarkdownURL, let root = pendingAccessRoot else { return }
            beginMarkdownImport(markdownURL: md, accessRoot: root, extraImages: urls)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if pendingImportKind == .markdownImages, let md = pendingMarkdownURL, let root = pendingAccessRoot {
            // User skipped images — still import text-only.
            beginMarkdownImport(markdownURL: md, accessRoot: root, extraImages: [])
        }
    }

    private func handlePickedMarkdown(_ url: URL) {
        pendingMarkdownURL = url
        pendingAccessRoot = url.deletingLastPathComponent()

        let needsImages = MarkdownStudyImporter.referencesLocalImages(in: url)
        guard let root = pendingAccessRoot else { return }
        if !needsImages {
            beginMarkdownImport(markdownURL: url, accessRoot: root, extraImages: [])
            return
        }

        let alert = UIAlertController(
            title: "这篇引用了本地插图",
            message: """
            多个 md 共用 assets 时，第二步请进 assets 全选图片即可。
            会按文件名自动甄别，只导入本文引用到的图，不会把整夹无关图都塞进来。

            也可先只导入正文。
            """,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "选择插图（可全选）", style: .default) { [weak self] _ in
            self?.presentImportPicker(kind: .markdownImages)
        })
        alert.addAction(UIAlertAction(title: "仅导入正文", style: .cancel) { [weak self] _ in
            guard let self, let md = self.pendingMarkdownURL, let root = self.pendingAccessRoot else { return }
            self.beginMarkdownImport(markdownURL: md, accessRoot: root, extraImages: [])
        })
        present(alert, animated: true)
    }

    private func beginMarkdownImport(markdownURL: URL, accessRoot: URL, extraImages: [URL]) {
        guard !isImportingMarkdown else { return }
        isImportingMarkdown = true
        setMarkdownImportBusy(true)
        StudyDocumentStore.shared.importMarkdown(
            markdownURL: markdownURL,
            accessRoot: accessRoot,
            extraImageFiles: extraImages
        ) { [weak self] result in
            guard let self else { return }
            self.isImportingMarkdown = false
            self.setMarkdownImportBusy(false)
            self.pendingMarkdownURL = nil
            self.pendingAccessRoot = nil
            switch result {
            case .failure(let error):
                self.presentImportError(error)
            case .success(let outcome):
                let docID = outcome.document.id
                let finish = { [weak self] in
                    guard let self else { return }
                    self.delegate?.studyDocumentPicker(self, didSelect: docID)
                }
                if outcome.missingImagePaths.isEmpty {
                    finish()
                } else {
                    let sample = outcome.missingImagePaths.prefix(5).joined(separator: "\n")
                    let more = outcome.missingImagePaths.count > 5 ? "\n…" : ""
                    let alert = UIAlertController(
                        title: "已导入（仍有图未匹配）",
                        message: """
                        未匹配 \(outcome.missingImagePaths.count) 张（按文件名对应）：
                        \(sample)\(more)

                        可删除后重导，并在第二步把 assets 里对应文件多选进来。
                        """,
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: "好", style: .default) { _ in finish() })
                    self.present(alert, animated: true)
                }
            }
        }
    }

    private func setMarkdownImportBusy(_ busy: Bool) {
        tableView.isUserInteractionEnabled = !busy
        navigationItem.leftBarButtonItem?.isEnabled = !busy
        if busy {
            let indicator = UIActivityIndicatorView(style: .gray)
            indicator.startAnimating()
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: indicator)
        } else {
            navigationItem.rightBarButtonItem = nil
        }
    }

    private func presentImportError(_ error: Error) {
        let alert = UIAlertController(title: "导入失败", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}
