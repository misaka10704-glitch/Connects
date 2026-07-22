import UIKit
import PDFKit

final class PDFContentsViewController: UIViewController {
    enum Tab: Int {
        case outline = 0
        case bookmarks = 1
    }

    private struct OutlineRow {
        let title: String
        let destination: PDFDestination
        let level: Int
    }

    private let segmented = UISegmentedControl(items: ["目录", "书签"])
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let addBookmarkButton = UIButton(type: .system)
    private let emptyLabel = UILabel()

    private var activeTab: Tab = .outline
    private var outlineRows: [OutlineRow] = []
    private var bookmarkRows: [PDFBookmark] = []

    var document: PDFDocument?
    var documentID: String?
    var onSelectDestination: ((PDFDestination) -> Void)?
    var onSelectPageIndex: ((Int) -> Void)?
    var currentPageIndexProvider: (() -> Int)?
    var currentPageLabelProvider: (() -> String)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DSTheme.c.background

        segmented.selectedSegmentIndex = 0
        segmented.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
        segmented.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 13.0, *) {
            // Keep compact control height on newer SDKs.
        }
        view.addSubview(segmented)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 34
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        tableView.backgroundColor = DSTheme.c.background
        tableView.tableFooterView = UIView()
        if #available(iOS 11.0, *) {
            tableView.contentInsetAdjustmentBehavior = .never
        }
        view.addSubview(tableView)

        addBookmarkButton.translatesAutoresizingMaskIntoConstraints = false
        addBookmarkButton.setTitle("添加书签", for: .normal)
        addBookmarkButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        addBookmarkButton.addTarget(self, action: #selector(addBookmarkTapped), for: .touchUpInside)
        view.addSubview(addBookmarkButton)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = UIFont.systemFont(ofSize: 13)
        emptyLabel.textColor = DSTheme.c.textSecondary
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            segmented.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            segmented.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            segmented.heightAnchor.constraint(equalToConstant: 28),

            addBookmarkButton.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 4),
            addBookmarkButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            addBookmarkButton.heightAnchor.constraint(equalToConstant: 28),

            tableView.topAnchor.constraint(equalTo: addBookmarkButton.bottomAnchor, constant: 2),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 14),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -14)
        ])

        reloadData()
    }

    func reloadData() {
        outlineRows = collectOutlineRows(from: document?.outlineRoot)
        if let documentID = documentID {
            bookmarkRows = PDFBookmarkStore.shared.bookmarks(for: documentID)
        } else {
            bookmarkRows = []
        }
        updateChrome()
        tableView.reloadData()
    }

    private func updateChrome() {
        let c = DSTheme.c
        view.backgroundColor = c.background
        tableView.backgroundColor = c.background
        segmented.backgroundColor = c.inputBackground
        if #available(iOS 13.0, *) {
            segmented.selectedSegmentTintColor = c.background
        }
        segmented.setTitleTextAttributes([.foregroundColor: c.textPrimary, .font: UIFont.systemFont(ofSize: 12, weight: .medium)], for: .selected)
        segmented.setTitleTextAttributes([.foregroundColor: c.textSecondary, .font: UIFont.systemFont(ofSize: 12)], for: .normal)
        addBookmarkButton.tintColor = c.accent
        addBookmarkButton.isHidden = activeTab != .bookmarks
        emptyLabel.textColor = c.textSecondary

        switch activeTab {
        case .outline:
            emptyLabel.text = outlineRows.isEmpty ? "此 PDF 没有目录" : nil
        case .bookmarks:
            emptyLabel.text = bookmarkRows.isEmpty ? "暂无书签" : nil
        }
        emptyLabel.isHidden = emptyLabel.text == nil
    }

    @objc private func tabChanged() {
        activeTab = Tab(rawValue: segmented.selectedSegmentIndex) ?? .outline
        updateChrome()
        tableView.reloadData()
    }

    @objc private func addBookmarkTapped() {
        guard let documentID = documentID,
              let pageIndex = currentPageIndexProvider?() else { return }
        let defaultTitle = currentPageLabelProvider?() ?? "第 \(pageIndex + 1) 页"
        promptBookmarkTitle(defaultTitle: defaultTitle) { [weak self] title in
            guard let self = self,
                  let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return }
            PDFBookmarkStore.shared.add(
                PDFBookmark(title: title, pageIndex: pageIndex),
                documentID: documentID
            )
            self.reloadData()
        }
    }

    private func promptBookmarkTitle(defaultTitle: String, completion: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: "添加书签", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = defaultTitle
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completion(nil) })
        alert.addAction(UIAlertAction(title: "添加", style: .default) { _ in
            completion(alert.textFields?.first?.text)
        })
        present(alert, animated: true)
    }

    private func collectOutlineRows(from outline: PDFOutline?, level: Int = 0) -> [OutlineRow] {
        guard let outline = outline else { return [] }
        var rows: [OutlineRow] = []
        for index in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: index) else { continue }
            let title = child.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = (title?.isEmpty == false) ? title! : "未命名"
            if let destination = child.destination {
                rows.append(OutlineRow(title: label, destination: destination, level: level))
            }
            rows.append(contentsOf: collectOutlineRows(from: child, level: level + 1))
        }
        return rows
    }
}

extension PDFContentsViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch activeTab {
        case .outline: return outlineRows.count
        case .bookmarks: return bookmarkRows.count
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "row")
        let c = DSTheme.c
        cell.backgroundColor = c.background
        cell.textLabel?.textColor = c.textPrimary
        cell.textLabel?.font = UIFont.systemFont(ofSize: 13)
        cell.detailTextLabel?.textColor = c.textSecondary
        cell.detailTextLabel?.font = UIFont.systemFont(ofSize: 11)
        cell.selectionStyle = .default
        cell.accessoryType = .none

        switch activeTab {
        case .outline:
            let row = outlineRows[indexPath.row]
            cell.textLabel?.text = row.title
            cell.textLabel?.numberOfLines = 2
            cell.detailTextLabel?.text = nil
            cell.indentationLevel = min(row.level, 6)
            cell.indentationWidth = 10
        case .bookmarks:
            let row = bookmarkRows[indexPath.row]
            cell.textLabel?.text = row.title
            cell.textLabel?.numberOfLines = 2
            cell.detailTextLabel?.text = "第 \(row.pageIndex + 1) 页"
            cell.indentationLevel = 0
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch activeTab {
        case .outline:
            onSelectDestination?(outlineRows[indexPath.row].destination)
        case .bookmarks:
            onSelectPageIndex?(bookmarkRows[indexPath.row].pageIndex)
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard activeTab == .bookmarks, let documentID = documentID else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, done in
            if let id = self?.bookmarkRows[indexPath.row].id {
                PDFBookmarkStore.shared.remove(id: id, documentID: documentID)
                self?.reloadData()
            }
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }
}
