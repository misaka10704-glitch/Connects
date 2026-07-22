import UIKit

/// Outline panel for Study Markdown — headings only (no PDF-style page bookmarks).
final class MarkdownContentsViewController: UIViewController {
    struct HeadingRow {
        let id: String
        let title: String
        let level: Int
    }

    private let titleLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    private var rows: [HeadingRow] = []

    var onSelectHeadingID: ((String) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DSTheme.c.background

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "目录"
        titleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = DSTheme.c.textPrimary
        view.addSubview(titleLabel)

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

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = UIFont.systemFont(ofSize: 13)
        emptyLabel.textColor = DSTheme.c.textSecondary
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.text = "未找到标题"
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            tableView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 14),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -14)
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeChanged),
            name: .themeDidChange,
            object: nil
        )
        reloadEmptyState()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setHeadings(_ headings: [HeadingRow]) {
        rows = headings
        tableView.reloadData()
        reloadEmptyState()
    }

    @objc private func themeChanged() {
        view.backgroundColor = DSTheme.c.background
        titleLabel.textColor = DSTheme.c.textPrimary
        tableView.backgroundColor = DSTheme.c.background
        emptyLabel.textColor = DSTheme.c.textSecondary
        tableView.reloadData()
    }

    private func reloadEmptyState() {
        emptyLabel.isHidden = !rows.isEmpty
        tableView.isHidden = rows.isEmpty
    }
}

extension MarkdownContentsViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let id = "md.toc"
        let cell = tableView.dequeueReusableCell(withIdentifier: id)
            ?? UITableViewCell(style: .default, reuseIdentifier: id)
        let row = rows[indexPath.row]
        cell.textLabel?.text = row.title
        cell.textLabel?.numberOfLines = 2
        cell.textLabel?.font = UIFont.systemFont(ofSize: 13, weight: row.level <= 1 ? .semibold : .regular)
        cell.textLabel?.textColor = DSTheme.c.textPrimary
        cell.backgroundColor = DSTheme.c.background
        cell.selectionStyle = .default
        let indent = CGFloat(max(row.level - 1, 0)) * 10
        cell.separatorInset = UIEdgeInsets(top: 0, left: 12 + indent, bottom: 0, right: 10)
        cell.layoutMargins = UIEdgeInsets(top: 0, left: 12 + indent, bottom: 0, right: 10)
        if #available(iOS 11.0, *) {
            cell.preservesSuperviewLayoutMargins = false
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelectHeadingID?(rows[indexPath.row].id)
    }
}
