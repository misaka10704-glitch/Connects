import UIKit

protocol StudyDocumentPickerDelegate: AnyObject {
    func studyDocumentPicker(_ picker: StudyDocumentPickerViewController, didSelect documentID: String)
    func studyDocumentPickerDidRequestImport(_ picker: StudyDocumentPickerViewController)
}

final class StudyDocumentPickerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate {
    weak var delegate: StudyDocumentPickerDelegate?

    private let tableView = UITableView(frame: .zero, style: .grouped)
    private var documents: [StudyDocument] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "选择 PDF"
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
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "StudyDocCell")
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
        documents.count + 1
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "StudyDocCell", for: indexPath)
        cell.backgroundColor = DSTheme.c.surface
        cell.textLabel?.font = DSTheme.bodyFont(size: 15)
        cell.textLabel?.textColor = DSTheme.c.textPrimary
        cell.accessoryType = .none
        if indexPath.row == 0 {
            cell.textLabel?.text = "从文件导入…"
            cell.imageView?.image = ActionIconFactory.image(.plus, pointSize: 16)
        } else {
            let doc = documents[indexPath.row - 1]
            cell.textLabel?.text = doc.title
            cell.imageView?.image = ActionIconFactory.image(.book, pointSize: 16)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.row == 0 {
            delegate?.studyDocumentPickerDidRequestImport(self)
            return
        }
        let doc = documents[indexPath.row - 1]
        delegate?.studyDocumentPicker(self, didSelect: doc.id)
    }

    func presentImportPicker(from presenter: UIViewController) {
        let picker = UIDocumentPickerViewController(documentTypes: ["com.adobe.pdf"], in: .import)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        presenter.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        do {
            let doc = try StudyDocumentStore.shared.importPDF(from: url)
            delegate?.studyDocumentPicker(self, didSelect: doc.id)
        } catch {
            let alert = UIAlertController(title: "导入失败", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            present(alert, animated: true)
        }
    }
}
