import UIKit

/// Clean form-style settings — no nested colored blocks, no reload-embedding bugs.
final class SettingsViewController: UIViewController, ThemeRefreshable, UITextFieldDelegate {
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    private let appearanceControl = UISegmentedControl(items: AppearanceMode.allCases.map { $0.displayName })
    private let fontSizeControl = UISegmentedControl(items: ["小", "中", "大"])
    private let deepseekField = UITextField()
    private let kimiField = UITextField()
    private let kimiCNSwitch = UISwitch()
    private let kimiCNLabel = UILabel()
    private let thinkingSwitch = UISwitch()
    private let thinkingLabel = UILabel()

    private var sectionLabels: [UILabel] = []
    private var cards: [UIView] = []
    private var footerLabels: [UILabel] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设置"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "完成",
            style: .done,
            target: self,
            action: #selector(doneTapped)
        )
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeDidChange, object: nil)
        buildForm()
        applyTheme()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func applyTheme() {
        let c = DSTheme.c
        view.backgroundColor = c.sidebarBackground
        scrollView.backgroundColor = c.sidebarBackground
        navigationController?.navigationBar.barStyle = c.navBarStyle
        navigationController?.navigationBar.tintColor = c.accent
        navigationController?.navigationBar.barTintColor = c.sidebarBackground
        navigationController?.navigationBar.isTranslucent = false
        navigationController?.navigationBar.titleTextAttributes = [.foregroundColor: c.textPrimary]

        for label in sectionLabels {
            label.textColor = c.textSecondary
        }
        for label in footerLabels {
            label.textColor = c.textTertiary
        }
        for card in cards {
            card.backgroundColor = c.surface
            card.layer.borderColor = c.border.cgColor
        }

        deepseekField.textColor = c.textPrimary
        deepseekField.tintColor = c.accent
        deepseekField.attributedPlaceholder = NSAttributedString(
            string: "sk-… DeepSeek",
            attributes: [.foregroundColor: c.textTertiary]
        )
        kimiField.textColor = c.textPrimary
        kimiField.tintColor = c.accent
        kimiField.attributedPlaceholder = NSAttributedString(
            string: "sk-… Kimi / Moonshot",
            attributes: [.foregroundColor: c.textTertiary]
        )
        kimiCNLabel.textColor = c.textPrimary
        kimiCNSwitch.onTintColor = c.accent
        thinkingLabel.textColor = c.textPrimary
        thinkingSwitch.onTintColor = c.accent

        appearanceControl.tintColor = c.accent
        fontSizeControl.tintColor = c.accent
        if #available(iOS 13.0, *) {
            appearanceControl.selectedSegmentTintColor = c.accent
            appearanceControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
            appearanceControl.setTitleTextAttributes([.foregroundColor: c.textPrimary], for: .normal)
            fontSizeControl.selectedSegmentTintColor = c.accent
            fontSizeControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
            fontSizeControl.setTitleTextAttributes([.foregroundColor: c.textPrimary], for: .normal)
        }
    }

    @objc private func themeChanged() { applyTheme() }

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

        contentStack.addArrangedSubview(makeSectionTitle("外观"))
        appearanceControl.selectedSegmentIndex = SettingsManager.shared.appearanceMode == .light ? 0 : 1
        appearanceControl.addTarget(self, action: #selector(appearanceChanged), for: .valueChanged)
        contentStack.addArrangedSubview(makeCard(embedding: appearanceControl, height: 36, inset: 12))
        contentStack.setCustomSpacing(16, after: contentStack.arrangedSubviews.last!)

        contentStack.addArrangedSubview(makeSectionTitle("聊天字号"))
        fontSizeControl.selectedSegmentIndex = SettingsManager.shared.chatFontSizeIndex
        fontSizeControl.addTarget(self, action: #selector(fontSizeChanged), for: .valueChanged)
        contentStack.addArrangedSubview(makeCard(embedding: fontSizeControl, height: 36, inset: 12))
        let fontTip = UILabel()
        fontTip.numberOfLines = 0
        fontTip.font = DSTheme.bodyFont(size: 13)
        fontTip.text = "调整对话正文与思考区字号。侧栏可用聊天页左上角「关闭 / 侧栏」切换。"
        footerLabels.append(fontTip)
        contentStack.addArrangedSubview(fontTip)
        contentStack.setCustomSpacing(22, after: fontTip)

        contentStack.addArrangedSubview(makeSectionTitle("模型行为"))
        let thinkRow = makeSwitchRow(
            label: thinkingLabel,
            text: "深度思考（关闭后 Kimi / DeepSeek 更快）",
            sw: thinkingSwitch,
            isOn: SettingsManager.shared.thinkingEnabled,
            action: #selector(thinkingChanged)
        )
        contentStack.addArrangedSubview(thinkRow)
        let thinkTip = UILabel()
        thinkTip.numberOfLines = 0
        thinkTip.font = DSTheme.bodyFont(size: 13)
        thinkTip.text = "Kimi K2.6 / DeepSeek V4 默认会先输出长段思考再写正文，首字会很慢。关掉即 Instant 模式。"
        footerLabels.append(thinkTip)
        contentStack.addArrangedSubview(thinkTip)
        contentStack.setCustomSpacing(22, after: thinkTip)

        contentStack.addArrangedSubview(makeSectionTitle("DeepSeek（Pro / Flash 共用）"))
        configureField(deepseekField)
        deepseekField.text = SettingsManager.shared.deepseekAPIKey
        contentStack.addArrangedSubview(makeCard(embedding: deepseekField, height: 44, inset: 0))
        contentStack.setCustomSpacing(22, after: contentStack.arrangedSubviews.last!)

        contentStack.addArrangedSubview(makeSectionTitle("Kimi"))
        configureField(kimiField)
        kimiField.text = SettingsManager.shared.kimiAPIKey
        contentStack.addArrangedSubview(makeCard(embedding: kimiField, height: 44, inset: 0))

        let cnRow = makeSwitchRow(
            label: kimiCNLabel,
            text: "国内节点 api.moonshot.cn（国内强烈建议开）",
            sw: kimiCNSwitch,
            isOn: SettingsManager.shared.kimiUseChinaEndpoint,
            action: #selector(kimiCNChanged)
        )
        contentStack.addArrangedSubview(cnRow)

        let tip = UILabel()
        tip.numberOfLines = 0
        tip.font = DSTheme.bodyFont(size: 13)
        tip.text = "Key 存在本机钥匙串。DeepSeek 与 Kimi 的 Key 不能混用。Kimi 很慢时：①确认深度思考已关 ②切换国内/海外节点试一次（Key 要与平台匹配：.cn Key 配 .cn）③新开对话（旧会话里的长思考记录会拖慢 Instant）。首包超过约 4 秒时顶栏会显示耗时与主机名。\n\n输入栏地球图标可开「联网」：发送前先检索网页摘要再回答，适合时效/事实题；默认关闭以保速度。"
        footerLabels.append(tip)
        contentStack.addArrangedSubview(tip)
        contentStack.setCustomSpacing(22, after: tip)

        contentStack.addArrangedSubview(makeSectionTitle("网课侧拉（Slide Over）"))
        let slideTip = UILabel()
        slideTip.numberOfLines = 0
        slideTip.font = DSTheme.bodyFont(size: 13)
        slideTip.text = """
        全屏上网课时可把 Connects 侧拉到屏幕一侧一起用：
        ① 打开网课后，从屏幕底部上滑露出 Dock
        ② 长按 Connects 图标，拖到屏幕右侧松手（进入侧拉）
        ③ 侧拉窗口里点左上角打开对话列表，或从左边缘向右滑
        ④ 再点一下侧拉把手可收起，网课继续全屏看
        """
        footerLabels.append(slideTip)
        contentStack.addArrangedSubview(slideTip)
        contentStack.setCustomSpacing(22, after: slideTip)

        contentStack.addArrangedSubview(makeSectionTitle("关于"))
        let about = UILabel()
        about.numberOfLines = 0
        about.font = DSTheme.bodyFont(size: 14)
        about.text = "Connects · iPad · iOS 12+ · 支持 Slide Over 侧拉 · 可选联网搜索"
        footerLabels.append(about)
        contentStack.addArrangedSubview(about)
    }

    private func makeSectionTitle(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text.uppercased()
        label.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        sectionLabels.append(label)
        return label
    }

    private func makeCard(embedding child: UIView, height: CGFloat, inset: CGFloat) -> UIView {
        let card = UIView()
        card.layer.cornerRadius = 12
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

    private func makeSwitchRow(label: UILabel, text: String, sw: UISwitch, isOn: Bool, action: Selector) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = DSTheme.bodyFont(size: 14)
        label.numberOfLines = 2
        sw.translatesAutoresizingMaskIntoConstraints = false
        sw.isOn = isOn
        sw.addTarget(self, action: action, for: .valueChanged)
        row.addSubview(label)
        row.addSubview(sw)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: sw.leadingAnchor, constant: -8),
            sw.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            sw.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40)
        ])
        return row
    }

    private func configureField(_ field: UITextField) {
        field.font = DSTheme.monoFont(size: 14)
        field.borderStyle = .none
        field.isSecureTextEntry = true
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.clearButtonMode = .whileEditing
        field.delegate = self
        field.returnKeyType = .done
    }

    @objc private func doneTapped() {
        SettingsManager.shared.deepseekAPIKey = deepseekField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        SettingsManager.shared.kimiAPIKey = kimiField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        view.endEditing(true)
        dismiss(animated: true)
    }

    @objc private func appearanceChanged() {
        SettingsManager.shared.appearanceMode = appearanceControl.selectedSegmentIndex == 0 ? .light : .dark
    }

    @objc private func fontSizeChanged() {
        SettingsManager.shared.chatFontSizeIndex = fontSizeControl.selectedSegmentIndex
    }

    @objc private func kimiCNChanged() {
        SettingsManager.shared.kimiUseChinaEndpoint = kimiCNSwitch.isOn
    }

    @objc private func thinkingChanged() {
        SettingsManager.shared.thinkingEnabled = thinkingSwitch.isOn
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
