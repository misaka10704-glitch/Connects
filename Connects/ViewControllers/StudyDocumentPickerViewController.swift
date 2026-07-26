import UIKit

protocol StudyDocumentPickerDelegate: AnyObject {
    func studyDocumentPicker(_ picker: StudyDocumentPickerViewController, didSelect documentID: String)
}

final class StudyDocumentPickerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate, UIGestureRecognizerDelegate {
    weak var delegate: StudyDocumentPickerDelegate?

    private enum OpenKind {
        case pdf
        case markdown
        case text
        case markdownImages
        case rebind(documentID: String)
    }

    private let openRowCount = 3
    private let tableView = UITableView(frame: .zero, style: .grouped)
    private var documents: [StudyDocument] = []
    private var pendingOpenKind: OpenKind = .pdf
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
        documents.count + openRowCount
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
            cell.textLabel?.text = "打开 PDF…"
            cell.detailTextLabel?.text = "直接编辑原文件（划线与注释写回 PDF）"
            cell.imageView?.image = ActionIconFactory.image(.plus, pointSize: 16)
        } else if indexPath.row == 1 {
            cell.textLabel?.text = "打开 Markdown…"
            cell.detailTextLabel?.text = "直接编辑原 .md；有图可再选 assets"
            cell.imageView?.image = ActionIconFactory.image(.plus, pointSize: 16)
        } else if indexPath.row == 2 {
            cell.textLabel?.text = "打开代码 / 文本…"
            cell.detailTextLabel?.text = "优先 .v（Verilog）；亦支持 .c / .py / .txt"
            cell.imageView?.image = ActionIconFactory.image(.plus, pointSize: 16)
        } else {
            let doc = documents[indexPath.row - openRowCount]
            cell.textLabel?.text = doc.title
            let size = byteFormatter.string(fromByteCount: doc.fileSize)
            let opened = dateFormatter.string(from: doc.lastOpenedAt)
            let mode = doc.accessMode == .originalBookmark ? "原文件" : "副本"
            cell.detailTextLabel?.text = "\(doc.kindLabel) · \(mode) · \(size) · \(opened)"
            cell.imageView?.image = ActionIconFactory.image(.book, pointSize: 16)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.row == 0 {
            presentOpenPicker(kind: .pdf)
            return
        }
        if indexPath.row == 1 {
            presentOpenPicker(kind: .markdown)
            return
        }
        if indexPath.row == 2 {
            presentOpenPicker(kind: .text)
            return
        }
        let doc = documents[indexPath.row - openRowCount]
        if doc.accessMode == .originalBookmark {
            do {
                _ = try StudyDocumentStore.shared.resolvedURL(forID: doc.id)
                delegate?.studyDocumentPicker(self, didSelect: doc.id)
            } catch {
                promptRebind(document: doc)
            }
        } else {
            delegate?.studyDocumentPicker(self, didSelect: doc.id)
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "打开原文件后可在 Study 中编辑；向左滑动或长按可从列表移除（不删除外部原文件）。"
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        indexPath.row >= openRowCount
    }

    func tableView(
        _ tableView: UITableView,
        editActionsForRowAt indexPath: IndexPath
    ) -> [UITableViewRowAction]? {
        guard indexPath.row >= openRowCount else { return nil }
        let doc = documents[indexPath.row - openRowCount]
        let delete = UITableViewRowAction(style: .destructive, title: "移除") { [weak self] _, _ in
            self?.confirmDelete(document: doc)
        }
        return [delete]
    }

    func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, indexPath.row >= openRowCount else { return }
        confirmDelete(document: documents[indexPath.row - openRowCount])
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard indexPath.row >= openRowCount else { return nil }
        let doc = documents[indexPath.row - openRowCount]
        let delete = UIContextualAction(style: .destructive, title: "移除") { [weak self] _, _, completion in
            self?.confirmDelete(document: doc, completion: completion)
        }
        let config = UISwipeActionsConfiguration(actions: [delete])
        config.performsFirstActionWithFullSwipe = false
        return config
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: tableView)
        guard let indexPath = tableView.indexPathForRow(at: point), indexPath.row >= openRowCount else { return }
        let doc = documents[indexPath.row - openRowCount]
        tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
        var items = [
            ConnectsMenuItem(title: "从列表移除", icon: .trash, isDestructive: true) { [weak self] in
                self?.confirmDelete(document: doc)
            }
        ]
        if doc.accessMode == .originalBookmark {
            items.insert(ConnectsMenuItem(title: "重新定位原文件", icon: .edit) { [weak self] in
                self?.presentOpenPicker(kind: .rebind(documentID: doc.id))
            }, at: 0)
        }
        ConnectsMenu.present(
            from: self,
            title: doc.title,
            items: items,
            sourceView: tableView,
            sourceRect: CGRect(x: point.x, y: point.y, width: 1, height: 1)
        )
    }

    private func confirmDelete(document: StudyDocument, completion: ((Bool) -> Void)? = nil) {
        let msg: String
        if document.accessMode == .originalBookmark {
            msg = "仅从 Connects 列表移除书签与阅读进度，不会删除外部原文件。已依附此文档的对话会取消依附。"
        } else {
            msg = "应用内副本与阅读进度将移除；已依附此文档的对话会取消依附。"
        }
        let alert = UIAlertController(
            title: "移除「\(document.title)」？",
            message: msg,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
            completion?(false)
        })
        alert.addAction(UIAlertAction(title: "移除", style: .destructive) { _ in
            StudyDocumentStore.shared.delete(documentID: document.id)
            completion?(true)
        })
        present(alert, animated: true)
    }

    private func promptRebind(document: StudyDocument) {
        let alert = UIAlertController(
            title: "无法访问原文件",
            message: "权限可能已失效，请重新选择「\(document.title)」对应的文件。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "重新选择", style: .default) { [weak self] _ in
            self?.presentOpenPicker(kind: .rebind(documentID: document.id))
        })
        present(alert, animated: true)
    }

    private func presentOpenPicker(kind: OpenKind) {
        pendingOpenKind = kind
        let types: [String]
        let multi: Bool
        let sourceRow: Int
        switch kind {
        case .pdf, .rebind:
            types = ["com.adobe.pdf", "public.item", "public.data"]
            multi = false
            sourceRow = 0
        case .markdown:
            types = [
                "net.daringfireball.markdown",
                "public.markdown",
                "public.plain-text",
                "public.text",
                "public.item"
            ]
            multi = false
            sourceRow = 1
        case .text:
            types = ["public.plain-text", "public.source-code", "public.text", "public.item", "public.data"]
            multi = false
            sourceRow = 2
        case .markdownImages:
            types = ["public.image", "public.png", "public.jpeg", "com.compuserve.gif", "public.tiff"]
            multi = true
            sourceRow = 1
        }
        let picker = UIDocumentPickerViewController(documentTypes: types, in: .open)
        picker.delegate = self
        picker.allowsMultipleSelection = multi
        if let pop = picker.popoverPresentationController {
            pop.sourceView = tableView
            pop.sourceRect = tableView.rectForRow(at: IndexPath(row: sourceRow, section: 0))
        }
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch pendingOpenKind {
        case .pdf:
            guard let url = urls.first else { return }
            openInPlace(url)
        case .text:
            guard let url = urls.first else { return }
            openInPlace(url, forceText: true)
        case .markdown:
            guard let url = urls.first else { return }
            handlePickedMarkdown(url)
        case .markdownImages:
            guard let md = pendingMarkdownURL, let root = pendingAccessRoot else { return }
            beginMarkdownImport(markdownURL: md, accessRoot: root, extraImages: urls)
        case .rebind(let documentID):
            guard let url = urls.first else { return }
            do {
                let doc = try StudyDocumentStore.shared.rebindBookmark(documentID: documentID, from: url)
                delegate?.studyDocumentPicker(self, didSelect: doc.id)
            } catch {
                presentOpenError(error)
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if case .markdownImages = pendingOpenKind, let md = pendingMarkdownURL, let root = pendingAccessRoot {
            beginMarkdownImport(markdownURL: md, accessRoot: root, extraImages: [])
        }
    }

    private func openInPlace(_ url: URL, forceText: Bool = false) {
        do {
            let doc = try StudyDocumentStore.shared.openDocument(from: url, forceText: forceText)
            delegate?.studyDocumentPicker(self, didSelect: doc.id)
        } catch {
            presentOpenError(error)
        }
    }

    private func handlePickedMarkdown(_ url: URL) {
        pendingMarkdownURL = url
        pendingAccessRoot = url.deletingLastPathComponent()

        let needsImages = MarkdownStudyImporter.referencesLocalImages(in: url)
        guard let root = pendingAccessRoot else { return }
        if !needsImages {
            openInPlace(url)
            return
        }

        let alert = UIAlertController(
            title: "这篇引用了本地插图",
            message: """
            可直接打开原文件编辑正文；若需在阅读器中预览插图，可再选 assets（按文件名匹配，会复制进应用内副本）。

            推荐：无图预览时直接打开原文件。
            """,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "打开原文件", style: .default) { [weak self] _ in
            guard let url = self?.pendingMarkdownURL else { return }
            self?.pendingMarkdownURL = nil
            self?.pendingAccessRoot = nil
            self?.openInPlace(url)
        })
        alert.addAction(UIAlertAction(title: "选择插图并导入副本", style: .default) { [weak self] _ in
            self?.presentOpenPicker(kind: .markdownImages)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.pendingMarkdownURL = nil
            self?.pendingAccessRoot = nil
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
                self.presentOpenError(error)
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
                        title: "已打开（仍有图未匹配）",
                        message: """
                        未匹配 \(outcome.missingImagePaths.count) 张：
                        \(sample)\(more)
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

    private func presentOpenError(_ error: Error) {
        let alert = UIAlertController(title: "打开失败", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}
