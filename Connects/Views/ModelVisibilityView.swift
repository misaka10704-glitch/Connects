import UIKit

/// Cursor-style “Add or search model” + per-model visibility toggles.
final class ModelVisibilityView: UIView, UITextFieldDelegate {
    private let searchField = UITextField()
    private let listStack = UIStackView()
    private var filter = ""
    private var rowViews: [String: UIView] = [:]
    private var switches: [String: UISwitch] = [:]
    private var heightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
        reload()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: .themeDidChange, object: nil
        )
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
        reload()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() { applyTheme(); reload() }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 12
        layer.borderWidth = 1 / UIScreen.main.scale
        clipsToBounds = true

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.font = DSTheme.bodyFont(size: 14)
        searchField.placeholder = L("添加或搜索模型", "Add or search models")
        searchField.clearButtonMode = .whileEditing
        searchField.returnKeyType = .search
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        searchField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        searchField.leftViewMode = .always
        addSubview(searchField)

        let searchLine = UIView()
        searchLine.translatesAutoresizingMaskIntoConstraints = false
        searchLine.tag = 88
        addSubview(searchLine)

        listStack.translatesAutoresizingMaskIntoConstraints = false
        listStack.axis = .vertical
        listStack.spacing = 0
        addSubview(listStack)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            searchField.heightAnchor.constraint(equalToConstant: 40),

            searchLine.topAnchor.constraint(equalTo: searchField.bottomAnchor),
            searchLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            searchLine.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            listStack.topAnchor.constraint(equalTo: searchLine.bottomAnchor),
            listStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        heightConstraint = heightAnchor.constraint(equalToConstant: 200)
        heightConstraint?.isActive = true
        applyTheme()
    }

    func applyTheme() {
        let c = DSTheme.c
        backgroundColor = c.surface
        layer.borderColor = c.border.cgColor
        searchField.textColor = c.textPrimary
        searchField.tintColor = c.accent
        searchField.attributedPlaceholder = NSAttributedString(
            string: L("添加或搜索模型", "Add or search models"),
            attributes: [.foregroundColor: c.textTertiary]
        )
        viewWithTag(88)?.backgroundColor = c.divider
        for (id, row) in rowViews {
            row.backgroundColor = .clear
            if let label = row.viewWithTag(1) as? UILabel {
                label.textColor = c.textPrimary
            }
            if let sw = switches[id] {
                sw.onTintColor = c.accent
            }
            row.viewWithTag(99)?.backgroundColor = c.divider
        }
    }

    func reload() {
        SettingsManager.shared.ensureModelCatalogSynced()
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()
        switches.removeAll()

        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let models = AIModelOption.catalog.filter { m in
            guard !q.isEmpty else { return true }
            return m.displayName.lowercased().contains(q)
                || m.modelId.lowercased().contains(q)
                || m.providerDisplayName.lowercased().contains(q)
        }

        for (i, model) in models.enumerated() {
            let row = makeRow(model)
            listStack.addArrangedSubview(row)
            rowViews[model.stableID] = row
            if i < models.count - 1 {
                let line = UIView()
                line.tag = 99
                line.translatesAutoresizingMaskIntoConstraints = false
                line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
                let inset = UIView()
                inset.addSubview(line)
                line.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    line.leadingAnchor.constraint(equalTo: inset.leadingAnchor, constant: 14),
                    line.trailingAnchor.constraint(equalTo: inset.trailingAnchor, constant: -14),
                    line.topAnchor.constraint(equalTo: inset.topAnchor),
                    line.bottomAnchor.constraint(equalTo: inset.bottomAnchor),
                    inset.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale)
                ])
                listStack.addArrangedSubview(inset)
            }
        }
        applyTheme()
        let count = max(models.count, 1)
        heightConstraint?.constant = 44 + CGFloat(count) * 48 + CGFloat(max(0, count - 1))
    }

    private func makeRow(_ model: AIModelOption) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.tag = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = model.displayName
        label.font = DSTheme.bodyFont(size: 15)
        label.numberOfLines = 1

        let sw = UISwitch()
        sw.translatesAutoresizingMaskIntoConstraints = false
        sw.isOn = SettingsManager.shared.isModelEnabled(model)
        sw.accessibilityIdentifier = model.stableID
        sw.addTarget(self, action: #selector(toggleChanged(_:)), for: .valueChanged)
        switches[model.stableID] = sw

        row.addSubview(label)
        row.addSubview(sw)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 48),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: sw.leadingAnchor, constant: -10),
            sw.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            sw.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    @objc private func searchChanged() {
        filter = searchField.text ?? ""
        reload()
    }

    @objc private func toggleChanged(_ sw: UISwitch) {
        guard let id = sw.accessibilityIdentifier,
              let model = AIModelOption.option(stableID: id) else { return }
        let ok = SettingsManager.shared.setModelEnabled(model, enabled: sw.isOn)
        if !ok {
            sw.setOn(true, animated: true)
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
