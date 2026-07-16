import UIKit

/// Clean form-style settings — no nested colored blocks, no reload-embedding bugs.
final class SettingsViewController: UIViewController, ThemeRefreshable, UITextFieldDelegate, UITextViewDelegate {
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    private let appearanceControl = UISegmentedControl(items: AppearanceMode.allCases.map { $0.displayName })
    private let fontSizeControl = UISegmentedControl(items: ["小", "中", "大"])
    private let renderDebugSwitch = UISwitch()
    private let renderDebugLabel = UILabel()
    private let turnContextBarSwitch = UISwitch()
    private let turnContextBarLabel = UILabel()
    private let deepseekField = UITextField()
    private let kimiField = UITextField()
    private let dashscopeField = UITextField()
    private let zhipuField = UITextField()
    private let doubaoField = UITextField()
    private let doubaoEndpointField = UITextField()
    private let kimiCNSwitch = UISwitch()
    private let kimiCNLabel = UILabel()
    private let qwenCNSwitch = UISwitch()
    private let qwenCNLabel = UILabel()
    private let modelVisibility = ModelVisibilityView()
    private let agentsButton = UIButton(type: .system)

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
        dashscopeField.textColor = c.textPrimary
        dashscopeField.tintColor = c.accent
        dashscopeField.attributedPlaceholder = NSAttributedString(
            string: "sk-… DashScope / 通义",
            attributes: [.foregroundColor: c.textTertiary]
        )
        zhipuField.textColor = c.textPrimary
        zhipuField.tintColor = c.accent
        zhipuField.attributedPlaceholder = NSAttributedString(
            string: "智谱 API Key",
            attributes: [.foregroundColor: c.textTertiary]
        )
        doubaoField.textColor = c.textPrimary
        doubaoField.tintColor = c.accent
        doubaoField.attributedPlaceholder = NSAttributedString(
            string: "火山方舟 API Key",
            attributes: [.foregroundColor: c.textTertiary]
        )
        doubaoEndpointField.textColor = c.textPrimary
        doubaoEndpointField.tintColor = c.accent
        doubaoEndpointField.attributedPlaceholder = NSAttributedString(
            string: "可选 ep-… 接入点",
            attributes: [.foregroundColor: c.textTertiary]
        )
        kimiCNLabel.textColor = c.textPrimary
        kimiCNSwitch.onTintColor = c.accent
        qwenCNLabel.textColor = c.textPrimary
        qwenCNSwitch.onTintColor = c.accent
        modelVisibility.applyTheme()
        agentsButton.setTitleColor(c.accent, for: .normal)

        appearanceControl.tintColor = c.accent
        fontSizeControl.tintColor = c.accent
        renderDebugLabel.textColor = c.textPrimary
        renderDebugSwitch.onTintColor = c.accent
        turnContextBarLabel.textColor = c.textPrimary
        turnContextBarSwitch.onTintColor = c.accent
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
        contentStack.setCustomSpacing(12, after: fontTip)

        let turnContextRow = makeSwitchRow(
            label: turnContextBarLabel,
            text: "显示「问题」跳转条",
            sw: turnContextBarSwitch,
            isOn: SettingsManager.shared.turnContextBarEnabled,
            action: #selector(turnContextBarChanged)
        )
        contentStack.addArrangedSubview(makeCard(embedding: turnContextRow, height: 44, inset: 12))
        let turnContextTip = UILabel()
        turnContextTip.numberOfLines = 0
        turnContextTip.font = DSTheme.bodyFont(size: 13)
        turnContextTip.text = "聊天页顶部显示当前可见回复对应的问题；点按可从本对话全部问题中选择并跳转。"
        footerLabels.append(turnContextTip)
        contentStack.addArrangedSubview(turnContextTip)
        contentStack.setCustomSpacing(22, after: turnContextTip)

        contentStack.addArrangedSubview(makeSectionTitle("开发者"))
        let debugRow = makeSwitchRow(
            label: renderDebugLabel,
            text: "聊天布局调试框（红=列，绿=原生回复，蓝=用户气泡）",
            sw: renderDebugSwitch,
            isOn: SettingsManager.shared.renderDebugOverlayEnabled,
            action: #selector(renderDebugChanged)
        )
        contentStack.addArrangedSubview(debugRow)
        let debugTip = UILabel()
        debugTip.numberOfLines = 0
        debugTip.font = DSTheme.bodyFont(size: 13)
        debugTip.text = "用于排查气泡空白、高度异常等问题。开启后返回聊天页即可看到描边。"
        footerLabels.append(debugTip)
        contentStack.addArrangedSubview(debugTip)
        contentStack.setCustomSpacing(22, after: debugTip)

        contentStack.addArrangedSubview(makeSectionTitle("智能体"))
        agentsButton.setTitle("管理智能体", for: .normal)
        agentsButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        agentsButton.contentHorizontalAlignment = .left
        agentsButton.addTarget(self, action: #selector(openAgents), for: .touchUpInside)
        contentStack.addArrangedSubview(makeCard(embedding: agentsButton, height: 42, inset: 0))
        let agentsTip = UILabel()
        agentsTip.numberOfLines = 0
        agentsTip.font = DSTheme.bodyFont(size: 13)
        agentsTip.text = "创建或修改会话级智能体；查看、编辑和恢复 Memory 的记录、合并与注入 prompt。Memory 默认关闭，须在对话栏点「记」后才记录和使用。"
        footerLabels.append(agentsTip)
        contentStack.addArrangedSubview(agentsTip)
        contentStack.setCustomSpacing(22, after: agentsTip)

        contentStack.addArrangedSubview(makeSectionTitle("显示的模型"))
        contentStack.addArrangedSubview(modelVisibility)
        cards.append(modelVisibility)
        let visTip = UILabel()
        visTip.numberOfLines = 0
        visTip.font = DSTheme.bodyFont(size: 13)
        visTip.text = "关掉的模型不会出现在顶栏选择列表里。至少保留一个。"
        footerLabels.append(visTip)
        contentStack.addArrangedSubview(visTip)
        contentStack.setCustomSpacing(22, after: visTip)

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
        contentStack.setCustomSpacing(22, after: cnRow)

        contentStack.addArrangedSubview(makeSectionTitle("Qwen（DashScope）"))
        configureField(dashscopeField)
        dashscopeField.text = SettingsManager.shared.dashscopeAPIKey
        contentStack.addArrangedSubview(makeCard(embedding: dashscopeField, height: 44, inset: 0))
        let qwenCNRow = makeSwitchRow(
            label: qwenCNLabel,
            text: "国内节点 dashscope.aliyuncs.com",
            sw: qwenCNSwitch,
            isOn: SettingsManager.shared.qwenUseChinaEndpoint,
            action: #selector(qwenCNChanged)
        )
        contentStack.addArrangedSubview(qwenCNRow)
        contentStack.setCustomSpacing(22, after: qwenCNRow)

        contentStack.addArrangedSubview(makeSectionTitle("智谱 GLM"))
        configureField(zhipuField)
        zhipuField.text = SettingsManager.shared.zhipuAPIKey
        contentStack.addArrangedSubview(makeCard(embedding: zhipuField, height: 44, inset: 0))
        contentStack.setCustomSpacing(22, after: contentStack.arrangedSubviews.last!)

        contentStack.addArrangedSubview(makeSectionTitle("豆包（火山方舟）"))
        configureField(doubaoField)
        doubaoField.text = SettingsManager.shared.doubaoAPIKey
        contentStack.addArrangedSubview(makeCard(embedding: doubaoField, height: 44, inset: 0))
        configureField(doubaoEndpointField)
        doubaoEndpointField.isSecureTextEntry = false
        doubaoEndpointField.placeholder = "可选 ep-… 接入点"
        doubaoEndpointField.text = SettingsManager.shared.doubaoEndpointID
        contentStack.addArrangedSubview(makeCard(embedding: doubaoEndpointField, height: 44, inset: 0))

        let tip = UILabel()
        tip.numberOfLines = 0
        tip.font = DSTheme.bodyFont(size: 13)
        tip.text = "Key 存在本机钥匙串，不可混用。图片：Kimi / Qwen / 豆包。联网 / 深度思考：输入栏地球与灯泡图标。"
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
        about.text = "Connects · iPad · iOS 12+ · DeepSeek / Kimi / Qwen / GLM / 豆包 · 可选联网搜索"
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
        SettingsManager.shared.dashscopeAPIKey = dashscopeField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        SettingsManager.shared.zhipuAPIKey = zhipuField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        SettingsManager.shared.doubaoAPIKey = doubaoField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        SettingsManager.shared.doubaoEndpointID = doubaoEndpointField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        view.endEditing(true)
        dismiss(animated: true)
    }

    @objc private func appearanceChanged() {
        SettingsManager.shared.appearanceMode = appearanceControl.selectedSegmentIndex == 0 ? .light : .dark
    }

    @objc private func fontSizeChanged() {
        SettingsManager.shared.chatFontSizeIndex = fontSizeControl.selectedSegmentIndex
    }

    @objc private func renderDebugChanged() {
        SettingsManager.shared.renderDebugOverlayEnabled = renderDebugSwitch.isOn
    }

    @objc private func turnContextBarChanged() {
        SettingsManager.shared.turnContextBarEnabled = turnContextBarSwitch.isOn
    }

    @objc private func kimiCNChanged() {
        SettingsManager.shared.kimiUseChinaEndpoint = kimiCNSwitch.isOn
    }

    @objc private func qwenCNChanged() {
        SettingsManager.shared.qwenUseChinaEndpoint = qwenCNSwitch.isOn
    }

    @objc private func openAgents() {
        navigationController?.pushViewController(AgentListViewController(), animated: true)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
