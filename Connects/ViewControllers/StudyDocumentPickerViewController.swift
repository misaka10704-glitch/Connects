import UIKit

protocol StudyDocumentPickerDelegate: AnyObject {
    func studyDocumentPicker(_ picker: StudyDocumentPickerViewController, didSelect documentID: String)
}

final class StudyDocumentPickerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate {
    weak var delegate: StudyDocumentPickerDelegate?

    private enum ImportKind {
        case pdf
        case markdown
    }

    private let tableView = UITableView(frame: .zero, style: .grouped)
    private var documents: [StudyDocument] = []
    private var pendingImportKind: ImportKind = .pdf
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
        reload()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if tableView.gestureRecognizers?.contains(where: { $0 is UILongPressGestureRecognizer }) != true {
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPress.minimumPressDuration = 0.45
            tableView.addGestureRecognizer(longPress)
        }
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
            cell.detailTextLabel?.text = ".md / .markdown"
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
        switch kind {
        case .pdf:
            types = ["com.adobe.pdf"]
        case .markdown:
            types = [
                "net.daringfireball.markdown",
                "public.markdown",
                "public.plain-text",
                "public.text"
            ]
        }
        let picker = UIDocumentPickerViewController(documentTypes: types, in: .import)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        if let pop = picker.popoverPresentationController {
            let row = kind == .pdf ? 0 : 1
            pop.sourceView = tableView
            pop.sourceRect = tableView.rectForRow(at: IndexPath(row: row, section: 0))
        }
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        do {
            let doc: StudyDocument
            switch pendingImportKind {
            case .pdf:
                doc = try StudyDocumentStore.shared.importPDF(from: url)
            case .markdown:
                let ext = url.pathExtension.lowercased()
                if ext == "pdf" {
                    throw StudyDocumentError.unsupportedType
                }
                doc = try StudyDocumentStore.shared.importMarkdown(from: url)
            }
            delegate?.studyDocumentPicker(self, didSelect: doc.id)
        } catch {
            let alert = UIAlertController(title: "导入失败", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            present(alert, animated: true)
        }
    }
}
