import UIKit
import PDFKit

/// Side panel with one-tap cycle: 目录 → 书签 → 标注 → …
final class PDFContentsViewController: UIViewController {
    enum Tab: Int, CaseIterable {
        case outline = 0
        case bookmarks = 1
        case annotations = 2

        var title: String {
            switch self {
            case .outline: return "目录"
            case .bookmarks: return "书签"
            case .annotations: return "标注"
            }
        }

        var next: Tab {
            let all = Tab.allCases
            return all[(rawValue + 1) % all.count]
        }
    }

    private struct OutlineRow {
        let title: String
        let destination: PDFDestination
        let level: Int
    }

    private struct AnnotationRow {
        let title: String
        let pageIndex: Int
        let bounds: CGRect
        let annotation: PDFAnnotation
    }

    private let titleButton = UIButton(type: .system)
    private let addBookmarkButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()

    private var activeTab: Tab = .outline
    private var outlineRows: [OutlineRow] = []
    private var bookmarkRows: [PDFBookmark] = []
    private var annotationRows: [AnnotationRow] = []

    var document: PDFDocument?
    var documentID: String?
    var onSelectDestination: ((PDFDestination) -> Void)?
    var onSelectPageIndex: ((Int) -> Void)?
    var onSelectAnnotation: ((PDFAnnotation, Int) -> Void)?
    var onDeleteAnnotation: ((PDFAnnotation, Int) -> Void)?
    var currentPageIndexProvider: (() -> Int)?
    var currentPageLabelProvider: (() -> String)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DSTheme.reader.background

        titleButton.translatesAutoresizingMaskIntoConstraints = false
        titleButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        titleButton.contentHorizontalAlignment = .leading
        titleButton.addTarget(self, action: #selector(switchTabTapped), for: .touchUpInside)
        titleButton.accessibilityHint = "点按切换目录、书签与标注"
        view.addSubview(titleButton)

        addBookmarkButton.translatesAutoresizingMaskIntoConstraints = false
        addBookmarkButton.setTitle("添加", for: .normal)
        addBookmarkButton.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        addBookmarkButton.addTarget(self, action: #selector(addBookmarkTapped), for: .touchUpInside)
        view.addSubview(addBookmarkButton)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 34
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        tableView.backgroundColor = DSTheme.reader.background
        tableView.tableFooterView = UIView()
        if #available(iOS 11.0, *) {
            tableView.contentInsetAdjustmentBehavior = .never
        }
        view.addSubview(tableView)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = UIFont.systemFont(ofSize: 13)
        emptyLabel.textColor = DSTheme.reader.textSecondary
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            titleButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            titleButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            titleButton.heightAnchor.constraint(equalToConstant: 32),

            addBookmarkButton.centerYAnchor.constraint(equalTo: titleButton.centerYAnchor),
            addBookmarkButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            addBookmarkButton.leadingAnchor.constraint(greaterThanOrEqualTo: titleButton.trailingAnchor, constant: 8),

            titleButton.trailingAnchor.constraint(lessThanOrEqualTo: addBookmarkButton.leadingAnchor, constant: -8),

            tableView.topAnchor.constraint(equalTo: titleButton.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
        ])
        updateChrome()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyTheme()
        reloadData()
    }

    func reloadData() {
        outlineRows = collectOutlineRows(from: document?.outlineRoot)
        if let documentID {
            bookmarkRows = PDFBookmarkStore.shared.bookmarks(for: documentID)
        } else {
            bookmarkRows = []
        }
        annotationRows = collectBoxAnnotations(from: document)
        updateChrome()
        tableView.reloadData()
    }

    private func applyTheme() {
        let c = DSTheme.reader
        view.backgroundColor = c.background
        tableView.backgroundColor = c.background
        titleButton.setTitleColor(c.textPrimary, for: .normal)
        titleButton.tintColor = c.textPrimary
        addBookmarkButton.tintColor = c.accent
        emptyLabel.textColor = c.textSecondary
    }

    private func updateChrome() {
        applyTheme()
        // Title itself is the switch: tap 「目录」→「书签」→「标注」
        titleButton.setTitle("\(activeTab.title) ▾", for: .normal)
        titleButton.accessibilityLabel = activeTab.title
        titleButton.contentHorizontalAlignment = .leading
        addBookmarkButton.isHidden = activeTab != .bookmarks
        switch activeTab {
        case .outline:
            emptyLabel.text = outlineRows.isEmpty ? "未找到标题" : nil
        case .bookmarks:
            emptyLabel.text = bookmarkRows.isEmpty ? "暂无书签" : nil
        case .annotations:
            emptyLabel.text = annotationRows.isEmpty ? "暂无标注" : nil
        }
        emptyLabel.isHidden = emptyLabel.text == nil
    }

    @objc private func switchTabTapped() {
        activeTab = activeTab.next
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

    private func collectBoxAnnotations(from document: PDFDocument?) -> [AnnotationRow] {
        guard let document else { return [] }
        var rows: [AnnotationRow] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for ann in page.annotations {
                let named = ann.userName == StudyAskSelectionStore.boxAnnotationUserName
                let type = (ann.type ?? "").lowercased()
                guard named || type.contains("square") else { continue }
                if ann.userName == StudyAskSelectionStore.askAnnotationUserName { continue }
                let raw = ann.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = raw.isEmpty ? "第 \(pageIndex + 1) 页" : raw
                rows.append(AnnotationRow(
                    title: title,
                    pageIndex: pageIndex,
                    bounds: ann.bounds,
                    annotation: ann
                ))
            }
        }
        return rows
    }
}

extension PDFContentsViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch activeTab {
        case .outline: return outlineRows.count
        case .bookmarks: return bookmarkRows.count
        case .annotations: return annotationRows.count
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "row")
        let c = DSTheme.reader
        cell.backgroundColor = c.background
        cell.textLabel?.textColor = c.textPrimary
        cell.detailTextLabel?.textColor = c.textSecondary
        cell.detailTextLabel?.font = UIFont.systemFont(ofSize: 11)
        cell.selectionStyle = .default
        cell.accessoryType = .none
        cell.indentationLevel = 0
        cell.separatorInset = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        cell.layoutMargins = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        cell.imageView?.image = nil
        if #available(iOS 11.0, *) {
            cell.preservesSuperviewLayoutMargins = false
        }

        switch activeTab {
        case .outline:
            let row = outlineRows[indexPath.row]
            cell.textLabel?.text = row.title
            cell.textLabel?.numberOfLines = 2
            cell.textLabel?.font = UIFont.systemFont(ofSize: 13, weight: row.level <= 0 ? .semibold : .regular)
            cell.detailTextLabel?.text = nil
            let indent = CGFloat(min(row.level, 6)) * 10
            cell.separatorInset = UIEdgeInsets(top: 0, left: 12 + indent, bottom: 0, right: 10)
            cell.layoutMargins = UIEdgeInsets(top: 0, left: 12 + indent, bottom: 0, right: 10)
        case .bookmarks:
            let row = bookmarkRows[indexPath.row]
            cell.textLabel?.text = row.title
            cell.textLabel?.numberOfLines = 2
            cell.textLabel?.font = UIFont.systemFont(ofSize: 13)
            cell.detailTextLabel?.text = "第 \(row.pageIndex + 1) 页"
        case .annotations:
            let row = annotationRows[indexPath.row]
            let raw = row.annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            cell.textLabel?.text = row.title
            cell.textLabel?.numberOfLines = 2
            cell.textLabel?.font = UIFont.systemFont(ofSize: 13)
            cell.textLabel?.textColor = raw.isEmpty
                ? c.textSecondary
                : UIColor(
                    red: ReadingAnnotationStyle.pdfBoxRed.r,
                    green: ReadingAnnotationStyle.pdfBoxRed.g,
                    blue: ReadingAnnotationStyle.pdfBoxRed.b,
                    alpha: 1
                )
            cell.detailTextLabel?.text = "第 \(row.pageIndex + 1) 页"
            let cfg = UIImage.SymbolConfiguration(pointSize: 8, weight: .regular)
            cell.imageView?.image = UIImage(systemName: "circle.fill", withConfiguration: cfg)?
                .withTintColor(
                    UIColor(
                        red: ReadingAnnotationStyle.pdfBoxRed.r,
                        green: ReadingAnnotationStyle.pdfBoxRed.g,
                        blue: ReadingAnnotationStyle.pdfBoxRed.b,
                        alpha: 1
                    ),
                    renderingMode: .alwaysOriginal
                )
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
        case .annotations:
            let row = annotationRows[indexPath.row]
            onSelectAnnotation?(row.annotation, row.pageIndex)
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        switch activeTab {
        case .bookmarks:
            guard let documentID else { return nil }
            guard bookmarkRows.indices.contains(indexPath.row) else { return nil }
            let delete = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, done in
                guard let self, self.bookmarkRows.indices.contains(indexPath.row) else {
                    done(false)
                    return
                }
                let id = self.bookmarkRows[indexPath.row].id
                self.bookmarkRows.remove(at: indexPath.row)
                PDFBookmarkStore.shared.remove(id: id, documentID: documentID)
                tableView.deleteRows(at: [indexPath], with: .fade)
                self.updateChrome()
                done(true)
            }
            let config = UISwipeActionsConfiguration(actions: [delete])
            config.performsFirstActionWithFullSwipe = true
            return config
        case .annotations:
            guard annotationRows.indices.contains(indexPath.row) else { return nil }
            let delete = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, done in
                guard let self, self.annotationRows.indices.contains(indexPath.row) else {
                    done(false)
                    return
                }
                let row = self.annotationRows.remove(at: indexPath.row)
                self.onDeleteAnnotation?(row.annotation, row.pageIndex)
                tableView.deleteRows(at: [indexPath], with: .fade)
                self.updateChrome()
                done(true)
            }
            let config = UISwipeActionsConfiguration(actions: [delete])
            config.performsFirstActionWithFullSwipe = true
            return config
        case .outline:
            return nil
        }
    }
}
