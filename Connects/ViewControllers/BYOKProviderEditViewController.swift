import UIKit

/// Add / edit a BYOK OpenAI-compatible provider.
/// Fields: name, base URL, API key, model id list, vision toggle.
final class BYOKProviderEditViewController: UIViewController, ThemeRefreshable, UITextFieldDelegate {
    /// Called after the profile (and key) is persisted.
    var onSave: (() -> Void)?

    private var provider: BYOKProvider  // working copy; id is stable
    private let isNew: Bool

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let nameField = UITextField()
    private let baseURLField = UITextField()
    private let keyField = UITextField()
    private let modelsView = UITextView()
    private let visionLabel = UILabel()
    private let visionSwitch = UISwitch()
    private let fetchModelsButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private var sectionLabels: [UILabel] = []
    private var footerLabels: [UILabel] = []
    private var cards: [UIView] = []
    private var fetchBusy = false

    init(provider: BYOKProvider?) {
        self.provider = provider ?? BYOKProvider()
        self.isNew = provider == nil
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Wraps the editor in a nav controller for modal presentation from Settings.
    func embeddedForSettings(onSave: @escaping () -> Void) -> UINavigationController {
        self.onSave = onSave
        let nav = UINavigationController(rootViewController: self)
        nav.modalPresentationStyle = .formSheet
        return nav
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isNew ? L("添加自定义服务", "Add Provider") : L("编辑自定义服务", "Edit Provider")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: L("取消", "Cancel"), style: .plain, target: self, action: #selector(cancelTapped)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L("保存", "Save"), style: .done, target: self, action: #selector(saveTapped)
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: .themeDidChange, object: nil
        )
        buildForm()
        applyTheme()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyOpaqueNavigationBar()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() { applyTheme() }

    private func applyOpaqueNavigationBar() {
        let c = DSTheme.c
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = c.sidebarBackground
        appearance.titleTextAttributes = [.foregroundColor: c.textPrimary]
        appearance.shadowColor = .clear
        guard let navBar = navigationController?.navigationBar else { return }
        navBar.standardAppearance = appearance
        navBar.scrollEdgeAppearance = appearance
        navBar.compactAppearance = appearance
        if #available(iOS 15.0, *) {
            navBar.compactScrollEdgeAppearance = appearance
        }
        navBar.isTranslucent = false
        navBar.tintColor = c.accent
        navBar.barStyle = c.navBarStyle
    }

    func applyTheme() {
        let c = DSTheme.c
        view.backgroundColor = c.sidebarBackground
        scrollView.backgroundColor = c.sidebarBackground
        modelsView.backgroundColor = c.surface
        applyOpaqueNavigationBar()
        for label in sectionLabels { label.textColor = c.textSecondary }
        for label in footerLabels { label.textColor = c.textTertiary }
        for card in cards {
            card.backgroundColor = c.surface
            card.layer.borderColor = c.border.cgColor
        }
        nameField.textColor = c.textPrimary
        baseURLField.textColor = c.textPrimary
        keyField.textColor = c.textPrimary
        modelsView.textColor = c.textPrimary
        modelsView.tintColor = c.accent
        visionLabel.textColor = c.textPrimary
        visionSwitch.onTintColor = c.accent
        fetchModelsButton.setTitleColor(c.accent, for: .normal)
    }

    private func buildForm() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .onDrag
        view.addSubview(scrollView)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 8
        contentStack.alignment = .fill
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 20),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -24),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40)
        ])

        // Name
        contentStack.addArrangedSubview(makeSectionTitle(L("名称", "Name")))
        configureField(nameField, placeholder: L("例如 OpenAI / OpenRouter / Groq", "e.g. OpenAI / OpenRouter / Groq"), secure: false)
        nameField.text = provider.name
        contentStack.addArrangedSubview(makeCard(embedding: nameField, height: 44))
        contentStack.setCustomSpacing(18, after: contentStack.arrangedSubviews.last!)

        // Base URL
        contentStack.addArrangedSubview(makeSectionTitle(L("Base URL", "Base URL")))
        configureField(baseURLField, placeholder: "https://api.openai.com/v1", secure: false)
        baseURLField.keyboardType = .URL
        baseURLField.text = provider.baseURL
        contentStack.addArrangedSubview(makeCard(embedding: baseURLField, height: 44))
        let urlTip = makeTip(L("OpenAI 兼容服务的地址。填到 /v1 即可，也支持直接填 …/chat/completions。", "Any OpenAI-compatible base. /v1 works, or a full …/chat/completions URL."))
        contentStack.addArrangedSubview(urlTip)
        contentStack.setCustomSpacing(18, after: urlTip)

        // API Key
        contentStack.addArrangedSubview(makeSectionTitle(L("API Key", "API Key")))
        configureField(keyField, placeholder: "sk-…", secure: true)
        keyField.text = SettingsManager.shared.customAPIKey(for: provider.id)
        contentStack.addArrangedSubview(makeCard(embedding: keyField, height: 44))
        contentStack.setCustomSpacing(18, after: contentStack.arrangedSubviews.last!)

        // Models
        contentStack.addArrangedSubview(makeSectionTitle(L("模型", "Models")))
        modelsView.translatesAutoresizingMaskIntoConstraints = false
        modelsView.font = DSTheme.monoFont(size: 14)
        modelsView.layer.cornerRadius = DSTheme.cardCornerRadius
        modelsView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        modelsView.text = provider.modelIDs.joined(separator: ", ")
        modelsView.autocapitalizationType = .none
        modelsView.autocorrectionType = .no
        let modelsCard = makeCard(embedding: modelsView, height: 96)
        contentStack.addArrangedSubview(modelsCard)

        fetchModelsButton.setTitle(L("从服务获取模型列表（GET /models）", "Fetch model list (GET /models)"), for: .normal)
        fetchModelsButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        fetchModelsButton.contentHorizontalAlignment = .left
        fetchModelsButton.addTarget(self, action: #selector(fetchModelsTapped), for: .touchUpInside)
        contentStack.addArrangedSubview(fetchModelsButton)
        let modelsTip = makeTip(L("模型 ID 用逗号分隔，例如：gpt-5.2, gpt-5-mini。会作为独立模型出现在选择列表里。", "Comma-separated model IDs, e.g. gpt-5.2, gpt-5-mini. Each appears in the picker."))
        contentStack.addArrangedSubview(modelsTip)
        contentStack.setCustomSpacing(18, after: modelsTip)

        // Vision
        let visionRow = makeSwitchRow(
            label: visionLabel,
            text: L("模型支持图片输入", "Models accept image input"),
            sw: visionSwitch,
            isOn: provider.supportsVision
        )
        contentStack.addArrangedSubview(makeCard(embedding: visionRow, height: 44, inset: 12))
        let visionTip = makeTip(L("开启后，此服务的模型可接收图片消息（OpenAI image_url 格式）。", "When on, these models can receive images (OpenAI image_url format)."))
        contentStack.addArrangedSubview(visionTip)
        contentStack.setCustomSpacing(22, after: visionTip)

        // Delete
        if !isNew {
            deleteButton.setTitle(L("删除此服务", "Delete this provider"), for: .normal)
            deleteButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
            deleteButton.setTitleColor(.systemRed, for: .normal)
            deleteButton.contentHorizontalAlignment = .left
            deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
            contentStack.addArrangedSubview(makeCard(embedding: deleteButton, height: 44))
        }
    }

    private func makeSectionTitle(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text.uppercased()
        label.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        sectionLabels.append(label)
        return label
    }

    private func makeTip(_ text: String) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.font = DSTheme.bodyFont(size: 13)
        label.text = text
        footerLabels.append(label)
        return label
    }

    private func makeCard(embedding child: UIView, height: CGFloat, inset: CGFloat = 0) -> UIView {
        let card = UIView()
        card.layer.cornerRadius = DSTheme.cardCornerRadius
        card.layer.borderWidth = 1 / UIScreen.main.scale
        cards.append(card)
        child.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset > 0 ? inset : 14),
            child.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: inset > 0 ? -inset : -14),
            child.topAnchor.constraint(equalTo: card.topAnchor, constant: inset > 0 ? inset : 0),
            child.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: inset > 0 ? -inset : 0),
            child.heightAnchor.constraint(equalToConstant: height),
            card.heightAnchor.constraint(equalToConstant: height + (inset > 0 ? inset * 2 : 0))
        ])
        return card
    }

    private func makeSwitchRow(label: UILabel, text: String, sw: UISwitch, isOn: Bool) -> UIView {
        let row = UIView()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = DSTheme.bodyFont(size: 14)
        label.numberOfLines = 0
        sw.translatesAutoresizingMaskIntoConstraints = false
        sw.isOn = isOn
        sw.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addSubview(label)
        row.addSubview(sw)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -2),
            label.trailingAnchor.constraint(equalTo: sw.leadingAnchor, constant: -10),
            sw.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            sw.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40)
        ])
        return row
    }

    private func configureField(_ field: UITextField, placeholder: String, secure: Bool) {
        field.font = DSTheme.monoFont(size: 14)
        field.borderStyle = .none
        field.isSecureTextEntry = secure
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.clearButtonMode = .whileEditing
        field.delegate = self
        field.returnKeyType = .done
        field.placeholder = placeholder
        field.tintColor = DSTheme.c.accent
    }

    private func showMessage(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("好", "OK"), style: .default))
        present(alert, animated: true)
    }

    @objc private func cancelTapped() {
        view.endEditing(true)
        dismiss(animated: true)
    }

    @objc private func saveTapped() {
        let base = (baseURLField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard BYOKProvider.isValidBaseURL(base) else {
            showMessage(L("Base URL 无效。请填 https://…/v1 形式的地址。", "Invalid Base URL — use an https://…/v1 style address."))
            return
        }
        let models = BYOKProvider.parseModelIDs(modelsView.text ?? "")
        guard !models.isEmpty else {
            showMessage(L("请至少填写一个模型 ID，或用「从服务获取模型列表」。", "Add at least one model ID, or fetch the list from the service."))
            return
        }
        provider.name = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        provider.baseURL = base
        provider.modelIDs = models
        provider.supportsVision = visionSwitch.isOn
        SettingsManager.shared.saveCustomProvider(provider)
        let key = (keyField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsManager.shared.setCustomAPIKey(key, for: provider.id)
        view.endEditing(true)
        onSave?()
        dismiss(animated: true)
    }

    @objc private func deleteTapped() {
        let alert = UIAlertController(
            title: L("删除此服务？", "Delete this provider?"),
            message: L("会同时移除其 API Key 与模型显示；已有对话不受影响。", "Removes its API key and hides its models; existing chats are unaffected."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("取消", "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("删除", "Delete"), style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            SettingsManager.shared.removeCustomProvider(id: self.provider.id)
            self.onSave?()
            self.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    @objc private func fetchModelsTapped() {
        guard !fetchBusy else { return }
        let base = (baseURLField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard BYOKProvider.isValidBaseURL(base) else {
            showMessage(L("先填写有效的 Base URL。", "Enter a valid Base URL first."))
            return
        }
        var probe = provider
        probe.baseURL = base
        guard let url = URL(string: probe.modelsListURL) else { return }
        let key = (keyField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        fetchBusy = true
        fetchModelsButton.isEnabled = false
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if !key.isEmpty {
            request.setValue("Bearer \(SettingsManager.sanitizeKey(key))", forHTTPHeaderField: "Authorization")
        }
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.fetchBusy = false
                self.fetchModelsButton.isEnabled = true
                if let error = error {
                    self.showMessage(L("获取失败：", "Fetch failed: ") + error.localizedDescription)
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    self.showMessage(L("获取失败 (HTTP \(http.statusCode))。此服务可能不支持 /models 列表，请手动填写模型 ID。", "Fetch failed (HTTP \(http.statusCode)). This service may not support /models — enter IDs manually."))
                    return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let list = json["data"] as? [[String: Any]] else {
                    self.showMessage(L("响应不是 OpenAI /models 格式，请手动填写模型 ID。", "Response is not OpenAI /models format — enter IDs manually."))
                    return
                }
                let ids = list.compactMap { $0["id"] as? String }.sorted()
                guard !ids.isEmpty else {
                    self.showMessage(L("服务返回了空的模型列表。", "The service returned an empty model list."))
                    return
                }
                self.modelsView.text = ids.joined(separator: ", ")
            }
        }.resume()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
