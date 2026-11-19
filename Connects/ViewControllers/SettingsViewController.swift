import UIKit
import UniformTypeIdentifiers

/// Clean form-style settings — no nested colored blocks, no reload-embedding bugs.
final class SettingsViewController: UIViewController, ThemeRefreshable, UITextFieldDelegate, UITextViewDelegate, UIDocumentPickerDelegate {
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    private let appearanceControl = UISegmentedControl(items: AppearanceMode.allCases.map { $0.displayName })
    private let languageControl = UISegmentedControl(items: AppLanguage.allCases.map { $0.displayName })
    private let fontSizeControl = UISegmentedControl(items: ["小", "中", "大"])
    private let keepScreenOnSwitch = UISwitch()
    private let keepScreenOnLabel = UILabel()
    private let reasoningEffortControl = UISegmentedControl(items: ReasoningEffortLevel.allCases.map { $0.displayName })
    private let renderDebugSwitch = UISwitch()
    private let renderDebugLabel = UILabel()
    private let turnContextBarSwitch = UISwitch()
    private let turnContextBarLabel = UILabel()
    private let deepseekField = UITextField()
    private let kimiField = UITextField()
    private let dashscopeField = UITextField()
    private let zhipuField = UITextField()
    private let doubaoField = UITextField()
    private let minimaxField = UITextField()
    private let stepfunField = UITextField()
    private let hunyuanField = UITextField()
    private let yiField = UITextField()
    private let siliconflowField = UITextField()

    /// All provider key fields — theme / show-plaintext / save iterate this.
    private var apiKeyFields: [UITextField] {
        [deepseekField, kimiField, dashscopeField, zhipuField, doubaoField,
         minimaxField, stepfunField, hunyuanField, yiField, siliconflowField]
    }
    private let doubaoEndpointField = UITextField()
    private let kimiCNSwitch = UISwitch()
    private let kimiCNLabel = UILabel()
    private let qwenCNSwitch = UISwitch()
    private let qwenCNLabel = UILabel()
    private let modelVisibility = ModelVisibilityView()
    private let exportBackupButton = UIButton(type: .system)
    private let importBackupButton = UIButton(type: .system)
    private let exportChatTransferButton = UIButton(type: .system)
    private let importChatTransferButton = UIButton(type: .system)
    private let exportKeysButton = UIButton(type: .system)
    private let importKeysButton = UIButton(type: .system)
    private var backupBusy = false
    private var pendingImportKind: BackupImportKind = .fullBackup

    private enum BackupImportKind {
        case fullBackup
        case chatTransfer
        case keysTransfer
    }

    private var sectionLabels: [UILabel] = []
    private var cards: [UIView] = []
    private var footerLabels: [UILabel] = []
    private var providerRowLabels: [UILabel] = []
    private var separatorLines: [UIView] = []
    private let showKeysLabel = UILabel()
    private let showKeysSwitch = UISwitch()
    private let byokListStack = UIStackView()
    private var byokRowViews: [UIView] = []
    private var doneBarButton: UIBarButtonItem?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("设置", "Settings")
        let done = UIBarButtonItem(
            title: L("完成", "Done"),
            style: .done,
            target: self,
            action: #selector(doneTapped)
        )
        doneBarButton = done
        navigationItem.rightBarButtonItem = done
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appLanguageChanged), name: .appLanguageDidChange, object: nil)
        buildForm()
        applyTheme()
    }

    /// Language switching swaps every label — rebuild the form rather than patching strings.
    private func rebuildForm() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        sectionLabels.removeAll()
        footerLabels.removeAll()
        providerRowLabels.removeAll()
        separatorLines.removeAll()
        cards.removeAll { $0 !== modelVisibility }
        buildForm()
        applyTheme()
    }

    @objc private func appLanguageChanged() { rebuildForm() }

    @objc private func languageChanged() {
        let modes = AppLanguage.allCases
        guard languageControl.selectedSegmentIndex >= 0,
              languageControl.selectedSegmentIndex < modes.count else { return }
        SettingsManager.shared.appLanguage = modes[languageControl.selectedSegmentIndex]
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyOpaqueNavigationBar(colors: DSTheme.c)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func applyOpaqueNavigationBar(colors c: ThemeColors) {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = c.sidebarBackground
        appearance.titleTextAttributes = [.foregroundColor: c.textPrimary]
        appearance.largeTitleTextAttributes = [.foregroundColor: c.textPrimary]
        appearance.shadowColor = .clear

        guard let navBar = navigationController?.navigationBar else { return }
        navBar.standardAppearance = appearance
        navBar.scrollEdgeAppearance = appearance
        navBar.compactAppearance = appearance
        if #available(iOS 15.0, *) {
            navBar.compactScrollEdgeAppearance = appearance
        }
        navBar.isTranslucent = false
        navBar.barTintColor = c.sidebarBackground
        navBar.tintColor = c.accent
        navBar.barStyle = c.navBarStyle
        navBar.titleTextAttributes = [.foregroundColor: c.textPrimary]
        navigationController?.view.backgroundColor = c.sidebarBackground
    }

    func applyTheme() {
        let c = DSTheme.c
        view.backgroundColor = c.sidebarBackground
        scrollView.backgroundColor = c.sidebarBackground
        applyOpaqueNavigationBar(colors: c)

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
        for line in separatorLines {
            line.backgroundColor = c.divider
        }

        for field in apiKeyFields + [doubaoEndpointField] {
            field.textColor = c.textPrimary
            field.tintColor = c.accent
            if let raw = field.placeholder {
                field.attributedPlaceholder = NSAttributedString(
                    string: raw,
                    attributes: [.foregroundColor: c.textTertiary]
                )
            }
        }
        for label in providerRowLabels {
            label.textColor = c.textPrimary
        }
        showKeysLabel.textColor = c.textPrimary
        showKeysSwitch.onTintColor = c.accent
        kimiCNLabel.textColor = c.textPrimary
        kimiCNSwitch.onTintColor = c.accent
        qwenCNLabel.textColor = c.textPrimary
        qwenCNSwitch.onTintColor = c.accent
        applyBYOKRowTheme()
        modelVisibility.applyTheme()
        exportBackupButton.setTitleColor(c.accent, for: .normal)
        exportChatTransferButton.setTitleColor(c.accent, for: .normal)
        exportKeysButton.setTitleColor(c.accent, for: .normal)
        importChatTransferButton.setTitleColor(c.accent, for: .normal)
        importKeysButton.setTitleColor(c.accent, for: .normal)
        if #available(iOS 13.0, *) {
            importBackupButton.setTitleColor(.systemRed, for: .normal)
        } else {
            importBackupButton.setTitleColor(UIColor(red: 239/255, green: 68/255, blue: 68/255, alpha: 1), for: .normal)
        }

        appearanceControl.tintColor = c.accent
        fontSizeControl.tintColor = c.accent
        renderDebugLabel.textColor = c.textPrimary
        renderDebugSwitch.onTintColor = c.accent
        turnContextBarLabel.textColor = c.textPrimary
        turnContextBarSwitch.onTintColor = c.accent
        keepScreenOnLabel.textColor = c.textPrimary
        keepScreenOnSwitch.onTintColor = c.accent
        reasoningEffortControl.tintColor = c.accent
        if #available(iOS 13.0, *) {
            appearanceControl.selectedSegmentTintColor = c.accent
            appearanceControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
            appearanceControl.setTitleTextAttributes([.foregroundColor: c.textPrimary], for: .normal)
            fontSizeControl.selectedSegmentTintColor = c.accent
            fontSizeControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
            fontSizeControl.setTitleTextAttributes([.foregroundColor: c.textPrimary], for: .normal)
            languageControl.tintColor = c.accent
            languageControl.selectedSegmentTintColor = c.accent
            languageControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
            languageControl.setTitleTextAttributes([.foregroundColor: c.textPrimary], for: .normal)
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

        // 1. API keys — one grouped card: provider rows + endpoint options.
        contentStack.addArrangedSubview(makeSectionTitle(L("API Key", "API Keys")))
        for field in apiKeyFields {
            configureField(field)
        }
        configureField(doubaoEndpointField)
        doubaoEndpointField.isSecureTextEntry = false
        deepseekField.text = SettingsManager.shared.deepseekAPIKey
        kimiField.text = SettingsManager.shared.kimiAPIKey
        dashscopeField.text = SettingsManager.shared.dashscopeAPIKey
        zhipuField.text = SettingsManager.shared.zhipuAPIKey
        doubaoField.text = SettingsManager.shared.doubaoAPIKey
        minimaxField.text = SettingsManager.shared.minimaxAPIKey
        stepfunField.text = SettingsManager.shared.stepfunAPIKey
        hunyuanField.text = SettingsManager.shared.hunyuanAPIKey
        yiField.text = SettingsManager.shared.yiAPIKey
        siliconflowField.text = SettingsManager.shared.siliconflowAPIKey
        doubaoEndpointField.text = SettingsManager.shared.doubaoEndpointID

        let keysCard = makeGroupedCard(rows: [
            makeProviderRow("DeepSeek", field: deepseekField, placeholder: "sk-…"),
            makeProviderRow("Kimi", field: kimiField, placeholder: "sk-…"),
            makeInlineSwitchRow(
                label: kimiCNLabel, text: L("Kimi 国内节点 api.moonshot.cn", "Kimi China endpoint (api.moonshot.cn)"),
                sw: kimiCNSwitch, isOn: SettingsManager.shared.kimiUseChinaEndpoint,
                action: #selector(kimiCNChanged)
            ),
            makeProviderRow("Qwen", field: dashscopeField, placeholder: "sk-…"),
            makeInlineSwitchRow(
                label: qwenCNLabel, text: L("Qwen 国内节点 dashscope", "Qwen China endpoint (DashScope)"),
                sw: qwenCNSwitch, isOn: SettingsManager.shared.qwenUseChinaEndpoint,
                action: #selector(qwenCNChanged)
            ),
            makeProviderRow(L("智谱 GLM", "Zhipu GLM"), field: zhipuField, placeholder: "API Key"),
            makeProviderRow(L("豆包", "Doubao"), field: doubaoField, placeholder: L("方舟 API Key", "Ark API Key")),
            makeProviderRow(L("豆包接入点", "Doubao endpoint"), field: doubaoEndpointField, placeholder: L("可选 ep-…", "optional ep-…")),
            makeProviderRow("MiniMax", field: minimaxField, placeholder: "API Key"),
            makeProviderRow(L("阶跃星辰", "StepFun"), field: stepfunField, placeholder: "API Key"),
            makeProviderRow(L("腾讯混元", "Hunyuan"), field: hunyuanField, placeholder: "API Key"),
            makeProviderRow(L("零一万物", "01.AI Yi"), field: yiField, placeholder: "API Key"),
            makeProviderRow(L("硅基流动", "SiliconFlow"), field: siliconflowField, placeholder: "API Key"),
            makeInlineSwitchRow(
                label: showKeysLabel, text: L("显示 API Key 明文", "Show API keys"),
                sw: showKeysSwitch, isOn: false,
                action: #selector(showKeysChanged)
            ),
        ])
        contentStack.addArrangedSubview(keysCard)
        let keyTip = makeTip(L("Key 存本机钥匙串；填完点右上角「完成」保存。深度思考在输入栏灯泡切换。", "Keys stay in the device Keychain. Tap Done to save. Toggle deep thinking via the composer bulb."))
        contentStack.addArrangedSubview(keyTip)
        contentStack.setCustomSpacing(22, after: keyTip)

        // 2. BYOK custom providers
        contentStack.addArrangedSubview(makeSectionTitle(L("自定义服务（OpenAI 兼容）", "Custom Providers (OpenAI-Compatible)")))
        byokListStack.translatesAutoresizingMaskIntoConstraints = false
        byokListStack.axis = .vertical
        byokListStack.spacing = 0
        let byokCard = makeGroupedCard(rows: [], stackOverride: byokListStack)
        contentStack.addArrangedSubview(byokCard)
        reloadBYOKRows()
        let byokTip = makeTip(L("接入任意 OpenAI 兼容端点（OpenAI、OpenRouter、Groq、Ollama 等）。模型以独立条目进入选择列表。", "Connect any OpenAI-compatible endpoint (OpenAI, OpenRouter, Groq, Ollama…). Models appear in the picker."))
        contentStack.addArrangedSubview(byokTip)
        contentStack.setCustomSpacing(22, after: byokTip)

        // 3. Visible models
        contentStack.addArrangedSubview(makeSectionTitle(L("显示的模型", "Visible Models")))
        contentStack.addArrangedSubview(modelVisibility)
        cards.append(modelVisibility)
        let visTip = makeTip(L("关掉的模型不会出现在顶栏选择列表里。至少保留一个。", "Hidden models are removed from the picker. Keep at least one."))
        contentStack.addArrangedSubview(visTip)
        contentStack.setCustomSpacing(22, after: visTip)

        // 4. Appearance & chat — one grouped card.
        contentStack.addArrangedSubview(makeSectionTitle(L("外观与聊天", "Appearance & Chat")))
        appearanceControl.selectedSegmentIndex = SettingsManager.shared.appearanceMode == .light ? 0 : 1
        appearanceControl.addTarget(self, action: #selector(appearanceChanged), for: .valueChanged)
        fontSizeControl.selectedSegmentIndex = SettingsManager.shared.chatFontSizeIndex
        fontSizeControl.addTarget(self, action: #selector(fontSizeChanged), for: .valueChanged)
        if let idx = ReasoningEffortLevel.allCases.firstIndex(of: SettingsManager.shared.reasoningEffort) {
            reasoningEffortControl.selectedSegmentIndex = idx
        } else {
            reasoningEffortControl.selectedSegmentIndex = 0
        }
        reasoningEffortControl.addTarget(self, action: #selector(reasoningEffortChanged), for: .valueChanged)
        if let idx = AppLanguage.allCases.firstIndex(of: SettingsManager.shared.appLanguage) {
            languageControl.selectedSegmentIndex = idx
        }
        languageControl.addTarget(self, action: #selector(languageChanged), for: .valueChanged)

        contentStack.addArrangedSubview(makeGroupedCard(rows: [
            makeLabeledControlRow(L("语言", "Language"), control: languageControl, controlHeight: 32),
            makeLabeledControlRow(L("外观", "Appearance"), control: appearanceControl, controlHeight: 32),
            makeLabeledControlRow(L("字号", "Font size"), control: fontSizeControl, controlHeight: 32),
            makeInlineSwitchRow(
                label: keepScreenOnLabel, text: L("保持屏幕常亮", "Keep screen on"),
                sw: keepScreenOnSwitch, isOn: SettingsManager.shared.keepScreenOn,
                action: #selector(keepScreenOnChanged)
            ),
            makeInlineSwitchRow(
                label: turnContextBarLabel, text: L("显示「问题」跳转条", "Show question bar"),
                sw: turnContextBarSwitch, isOn: SettingsManager.shared.turnContextBarEnabled,
                action: #selector(turnContextBarChanged)
            ),
            makeLabeledControlRow(L("Kimi 思考", "Kimi thinking"), control: reasoningEffortControl, controlHeight: 32),
        ]))
        let chatTip = makeTip(L("Kimi 思考默认「低」；也可在输入栏长按灯泡切换。常亮仅前台生效。", "Kimi thinking defaults to Low; long-press the composer bulb to change. Keep-awake applies while in the foreground."))
        contentStack.addArrangedSubview(chatTip)
        contentStack.setCustomSpacing(22, after: chatTip)

        // 5. Backup — one grouped card of action rows.
        contentStack.addArrangedSubview(makeSectionTitle(L("备份与迁移", "Backup & Transfer")))
        exportBackupButton.setTitle(L("导出完整备份", "Export full backup"), for: .normal)
        exportBackupButton.addTarget(self, action: #selector(exportBackupTapped), for: .touchUpInside)
        importBackupButton.setTitle(L("从完整备份恢复", "Restore from full backup"), for: .normal)
        importBackupButton.setTitleColor(.systemRed, for: .normal)
        importBackupButton.addTarget(self, action: #selector(importBackupTapped), for: .touchUpInside)
        exportChatTransferButton.setTitle(L("导出聊天迁移包", "Export chat transfer"), for: .normal)
        exportChatTransferButton.addTarget(self, action: #selector(exportChatTransferTapped), for: .touchUpInside)
        importChatTransferButton.setTitle(L("导入聊天迁移包", "Import chat transfer"), for: .normal)
        importChatTransferButton.addTarget(self, action: #selector(importChatTransferTapped), for: .touchUpInside)
        exportKeysButton.setTitle(L("导出 Key 设置", "Export key settings"), for: .normal)
        exportKeysButton.addTarget(self, action: #selector(exportKeysTapped), for: .touchUpInside)
        importKeysButton.setTitle(L("导入 Key 设置", "Import key settings"), for: .normal)
        importKeysButton.addTarget(self, action: #selector(importKeysTapped), for: .touchUpInside)
        let backupButtons = [
            exportBackupButton, importBackupButton,
            exportChatTransferButton, importChatTransferButton,
            exportKeysButton, importKeysButton,
        ]
        for button in backupButtons {
            button.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
            button.contentHorizontalAlignment = .left
        }
        contentStack.addArrangedSubview(makeGroupedCard(rows: backupButtons.map { makeButtonRow($0) }))
        let backupTip = makeTip(L("完整备份含对话+Study+设置+Key（恢复会覆盖）；迁移包仅对话；Key 设置含密钥勿公开分享。", "Full backup: chats + Study + settings + keys (restore overwrites). Chat transfer: chats only. Key settings contain secrets — share carefully."))
        contentStack.addArrangedSubview(backupTip)
        contentStack.setCustomSpacing(22, after: backupTip)

        // 6. Slide Over tip
        contentStack.addArrangedSubview(makeSectionTitle(L("网课侧拉（Slide Over）", "Slide Over")))
        let slideTip = makeTip(L("""
        全屏上网课时可把 Connects 侧拉到屏幕一侧一起用：
        ① 打开网课后，从屏幕底部上滑露出 Dock
        ② 长按 Connects 图标，拖到屏幕右侧松手（进入侧拉）
        ③ 侧拉窗口里点左上角打开对话列表，或从左边缘向右滑
        ④ 再点一下侧拉把手可收起，网课继续全屏看
        """, """
        Use Connects side-by-side with a full-screen lecture app:
        1. Swipe up from the bottom to reveal the Dock
        2. Long-press the Connects icon and drag it to the screen edge
        3. Tap the top-left button (or swipe from the left edge) for history
        4. Tap the grabber again to tuck Connects away
        """))
        contentStack.addArrangedSubview(slideTip)
        contentStack.setCustomSpacing(22, after: slideTip)

        // 7. Developer
        contentStack.addArrangedSubview(makeSectionTitle(L("开发者", "Developer")))
        let debugRow = makeInlineSwitchRow(
            label: renderDebugLabel, text: L("聊天布局调试框", "Chat layout debug frames"),
            sw: renderDebugSwitch, isOn: SettingsManager.shared.renderDebugOverlayEnabled,
            action: #selector(renderDebugChanged)
        )
        contentStack.addArrangedSubview(makeGroupedCard(rows: [debugRow]))

        // 8. About
        contentStack.addArrangedSubview(makeSectionTitle(L("关于", "About")))
        let about = makeTip("Connects · iPad · iOS 18+ · DeepSeek / Kimi / Qwen / GLM / Doubao + BYOK")
        about.font = DSTheme.bodyFont(size: 14)
        contentStack.addArrangedSubview(about)
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

    /// Grouped card stacking rows with hairline separators (iOS settings style).
    /// `stackOverride` lets BYOK own its stack for later reloads.
    private func makeGroupedCard(rows: [UIView], stackOverride: UIStackView? = nil) -> UIView {
        let card = UIView()
        card.layer.cornerRadius = DSTheme.cardCornerRadius
        card.layer.borderWidth = 1 / UIScreen.main.scale
        card.clipsToBounds = true
        cards.append(card)

        let stack = stackOverride ?? UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 0
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        for (i, row) in rows.enumerated() {
            if i > 0 { stack.addArrangedSubview(makeSeparator()) }
            stack.addArrangedSubview(row)
        }
        return card
    }

    private func makeSeparator() -> UIView {
        let line = UIView()
        line.tag = 99
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        separatorLines.append(line)
        let inset = UIView()
        inset.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: inset.leadingAnchor, constant: 14),
            line.trailingAnchor.constraint(equalTo: inset.trailingAnchor, constant: -14),
            line.topAnchor.constraint(equalTo: inset.topAnchor),
            line.bottomAnchor.constraint(equalTo: inset.bottomAnchor),
            inset.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale)
        ])
        return inset
    }

    /// Provider label + secure field on one row.
    private func makeProviderRow(_ title: String, field: UITextField, placeholder: String) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = title
        label.font = DSTheme.bodyFont(size: 14)
        label.setContentHuggingPriority(.required, for: .horizontal)
        providerRowLabels.append(label)
        field.placeholder = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.addSubview(field)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 46),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),
            field.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            field.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    /// Label + segmented/control on one row.
    private func makeLabeledControlRow(_ title: String, control: UIView, controlHeight: CGFloat) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = title
        label.font = DSTheme.bodyFont(size: 14)
        providerRowLabels.append(label)
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 50),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.heightAnchor.constraint(equalToConstant: controlHeight)
        ])
        return row
    }

    /// Switch row padded for use inside grouped cards.
    private func makeInlineSwitchRow(label: UILabel, text: String, sw: UISwitch, isOn: Bool, action: Selector) -> UIView {
        let row = makeSwitchRow(label: label, text: text, sw: sw, isOn: isOn, action: action)
        let padded = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        padded.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: padded.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: padded.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: padded.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: padded.bottomAnchor, constant: -6),
            padded.heightAnchor.constraint(greaterThanOrEqualToConstant: 46)
        ])
        return padded
    }

    /// Left-aligned text button row for grouped cards.
    private func makeButtonRow(_ button: UIButton) -> UIView {
        let padded = UIView()
        button.translatesAutoresizingMaskIntoConstraints = false
        padded.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: padded.leadingAnchor, constant: 14),
            button.trailingAnchor.constraint(equalTo: padded.trailingAnchor, constant: -14),
            button.topAnchor.constraint(equalTo: padded.topAnchor),
            button.bottomAnchor.constraint(equalTo: padded.bottomAnchor),
            padded.heightAnchor.constraint(equalToConstant: 44)
        ])
        return padded
    }

    // MARK: - BYOK provider rows

    private func reloadBYOKRows() {
        byokListStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        byokRowViews.removeAll()
        let providers = SettingsManager.shared.customProviders
        var rows: [UIView] = providers.map { makeBYOKRow($0) }
        rows.append(makeAddBYOKRow())
        for (i, row) in rows.enumerated() {
            if i > 0 { byokListStack.addArrangedSubview(makeSeparator()) }
            byokListStack.addArrangedSubview(row)
            byokRowViews.append(row)
        }
        applyBYOKRowTheme()
    }

    private func makeBYOKRow(_ provider: BYOKProvider) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let name = UILabel()
        name.tag = 1
        name.translatesAutoresizingMaskIntoConstraints = false
        name.text = provider.displayName
        name.font = DSTheme.bodyFont(size: 15)

        let detail = UILabel()
        detail.tag = 2
        detail.translatesAutoresizingMaskIntoConstraints = false
        let keyState = SettingsManager.shared.customAPIKey(for: provider.id).isEmpty ? L("未填 Key", "no key") : L("已填 Key", "key set")
        detail.text = L("\(provider.modelIDs.count) 个模型 · \(keyState)", "\(provider.modelIDs.count) models · \(keyState)")
        detail.font = DSTheme.bodyFont(size: 12)

        let chevron = UILabel()
        chevron.tag = 3
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.text = "›"
        chevron.font = UIFont.systemFont(ofSize: 20, weight: .medium)

        let tap = UIButton(type: .system)
        tap.translatesAutoresizingMaskIntoConstraints = false
        tap.accessibilityIdentifier = provider.id
        tap.addTarget(self, action: #selector(byokRowTapped(_:)), for: .touchUpInside)

        row.addSubview(name)
        row.addSubview(detail)
        row.addSubview(chevron)
        row.addSubview(tap)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            name.topAnchor.constraint(equalTo: row.topAnchor, constant: 9),
            name.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            chevron.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            tap.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            tap.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            tap.topAnchor.constraint(equalTo: row.topAnchor),
            tap.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        return row
    }

    private func makeAddBYOKRow() -> UIView {
        let button = UIButton(type: .system)
        button.tag = 4
        button.setTitle(L("＋ 添加自定义服务", "＋ Add custom provider"), for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        button.contentHorizontalAlignment = .left
        button.addTarget(self, action: #selector(addBYOKTapped), for: .touchUpInside)
        return makeButtonRow(button)
    }

    private func applyBYOKRowTheme() {
        let c = DSTheme.c
        for row in byokRowViews {
            if let name = row.viewWithTag(1) as? UILabel { name.textColor = c.textPrimary }
            if let detail = row.viewWithTag(2) as? UILabel { detail.textColor = c.textTertiary }
            if let chevron = row.viewWithTag(3) as? UILabel { chevron.textColor = c.textTertiary }
            if let add = row.viewWithTag(4) as? UIButton { add.setTitleColor(c.accent, for: .normal) }
        }
    }

    @objc private func byokRowTapped(_ sender: UIButton) {
        guard let id = sender.accessibilityIdentifier,
              let provider = SettingsManager.shared.customProvider(id: id) else { return }
        present(BYOKProviderEditViewController(provider: provider).embeddedForSettings { [weak self] in
            self?.reloadBYOKRows()
        }, animated: true)
    }

    @objc private func addBYOKTapped() {
        present(BYOKProviderEditViewController(provider: nil).embeddedForSettings { [weak self] in
            self?.reloadBYOKRows()
        }, animated: true)
    }

    @objc private func showKeysChanged() {
        let show = showKeysSwitch.isOn
        for field in apiKeyFields {
            field.isSecureTextEntry = !show
        }
    }

    private func makeSwitchRow(label: UILabel, text: String, sw: UISwitch, isOn: Bool, action: Selector) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = DSTheme.bodyFont(size: 14)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sw.translatesAutoresizingMaskIntoConstraints = false
        sw.isOn = isOn
        sw.addTarget(self, action: action, for: .valueChanged)
        sw.setContentCompressionResistancePriority(.required, for: .horizontal)
        sw.setContentHuggingPriority(.required, for: .horizontal)
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
        SettingsManager.shared.minimaxAPIKey = minimaxField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        SettingsManager.shared.stepfunAPIKey = stepfunField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        SettingsManager.shared.hunyuanAPIKey = hunyuanField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        SettingsManager.shared.yiAPIKey = yiField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        SettingsManager.shared.siliconflowAPIKey = siliconflowField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

    @objc private func keepScreenOnChanged() {
        SettingsManager.shared.keepScreenOn = keepScreenOnSwitch.isOn
    }

    @objc private func reasoningEffortChanged() {
        let idx = reasoningEffortControl.selectedSegmentIndex
        let levels = ReasoningEffortLevel.allCases
        guard idx >= 0, idx < levels.count else { return }
        SettingsManager.shared.reasoningEffort = levels[idx]
    }

    @objc private func kimiCNChanged() {
        SettingsManager.shared.kimiUseChinaEndpoint = kimiCNSwitch.isOn
    }

    @objc private func qwenCNChanged() {
        SettingsManager.shared.qwenUseChinaEndpoint = qwenCNSwitch.isOn
    }

    @objc private func exportBackupTapped() {
        exportPackage(
            fileStem: "ConnectsBackup",
            fileExtension: ConnectsBackupService.fileExtension
        ) { url in
            _ = try ConnectsBackupService.export(to: url)
        }
    }

    @objc private func importBackupTapped() {
        pendingImportKind = .fullBackup
        presentImportPicker()
    }

    @objc private func exportChatTransferTapped() {
        exportPackage(
            fileStem: "ConnectsChats",
            fileExtension: ConnectsChatTransferService.fileExtension
        ) { url in
            _ = try ConnectsChatTransferService.exportAll(to: url)
        }
    }

    @objc private func importChatTransferTapped() {
        pendingImportKind = .chatTransfer
        presentImportPicker()
    }

    @objc private func exportKeysTapped() {
        let alert = UIAlertController(
            title: L("导出 Key 设置？", "Export key settings?"),
            message: L("文件含 API Key 明文，请勿发到公共频道。", "The file contains plaintext API keys — do not share publicly."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("取消", "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("导出", "Export"), style: .default) { [weak self] _ in
            self?.exportPackage(
                fileStem: "ConnectsKeys",
                fileExtension: ConnectsKeysTransferService.fileExtension
            ) { url in
                _ = try ConnectsKeysTransferService.export(to: url)
            }
        })
        present(alert, animated: true)
    }

    @objc private func importKeysTapped() {
        pendingImportKind = .keysTransfer
        presentImportPicker()
    }

    private func presentImportPicker() {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.data, .archive],
            asCopy: true
        )
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    private func exportPackage(
        fileStem: String,
        fileExtension: String,
        work: @escaping (URL) throws -> Void
    ) {
        guard !backupBusy else { return }
        setBackupBusy(true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("connects-export-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let stamp = Self.backupStampFormatter.string(from: Date())
                let url = folder.appendingPathComponent("\(fileStem)_\(stamp).\(fileExtension)")
                try work(url)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.setBackupBusy(false)
                    let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    activity.completionWithItemsHandler = { _, _, _, _ in
                        try? FileManager.default.removeItem(at: folder)
                    }
                    if let popover = activity.popoverPresentationController {
                        popover.sourceView = self.view
                        popover.sourceRect = CGRect(
                            x: self.view.bounds.midX,
                            y: self.view.bounds.midY,
                            width: 1,
                            height: 1
                        )
                    }
                    self.present(activity, animated: true)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.setBackupBusy(false)
                    self.showBackupMessage(error.localizedDescription)
                }
            }
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let source = urls.first else { return }
        let accessing = source.startAccessingSecurityScopedResource()
        defer {
            if accessing { source.stopAccessingSecurityScopedResource() }
        }
        do {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("connects-import-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let localURL = folder.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: localURL)
            switch pendingImportKind {
            case .fullBackup:
                beginBackupRestore(from: localURL, stagingFolder: folder)
            case .chatTransfer:
                beginChatTransferImport(from: localURL, stagingFolder: folder)
            case .keysTransfer:
                beginKeysImport(from: localURL, stagingFolder: folder)
            }
        } catch {
            showBackupMessage(error.localizedDescription)
        }
    }

    private func beginBackupRestore(from url: URL, stagingFolder: URL) {
        let alert = UIAlertController(
            title: L("从完整备份恢复？", "Restore from full backup?"),
            message: L("将覆盖对话、项目、设置与 API Key 数据。此操作不可撤销。", "Overwrites chats, projects, settings and API keys. This cannot be undone."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("取消", "Cancel"), style: .cancel) { _ in
            try? FileManager.default.removeItem(at: stagingFolder)
        })
        alert.addAction(UIAlertAction(title: L("继续", "Continue"), style: .destructive) { [weak self] _ in
            self?.confirmBackupRestore(from: url, stagingFolder: stagingFolder)
        })
        present(alert, animated: true)
    }

    private func beginChatTransferImport(from url: URL, stagingFolder: URL) {
        let alert = UIAlertController(
            title: L("导入聊天迁移包？", "Import chat transfer?"),
            message: L("将合并导入对话：同 ID 覆盖本地，新对话追加。不含 API Key。", "Merges chats: same IDs overwrite, new ones append. No API keys included."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("取消", "Cancel"), style: .cancel) { _ in
            try? FileManager.default.removeItem(at: stagingFolder)
        })
        alert.addAction(UIAlertAction(title: L("导入", "Import"), style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.setBackupBusy(true)
            DispatchQueue.global(qos: .userInitiated).async {
                // Heavy unzip/decode off main; apply merge on main.
                let result: Result<ConnectsChatTransferSummary, Error>
                do {
                    let summary = try ConnectsChatTransferService.importPackage(from: url)
                    result = .success(summary)
                } catch {
                    result = .failure(error)
                }
                DispatchQueue.main.async {
                    self.setBackupBusy(false)
                    try? FileManager.default.removeItem(at: stagingFolder)
                    switch result {
                    case .success(let summary):
                        self.showBackupMessage(
                            L("已导入 \(summary.conversationCount) 条对话（新增 \(summary.addedCount)，覆盖 \(summary.mergedCount)）。",
                              "Imported \(summary.conversationCount) chats (\(summary.addedCount) new, \(summary.mergedCount) merged).")
                        )
                    case .failure(let error):
                        self.showBackupMessage(error.localizedDescription)
                    }
                }
            }
        })
        present(alert, animated: true)
    }

    private func beginKeysImport(from url: URL, stagingFolder: URL) {
        let alert = UIAlertController(
            title: L("导入 Key 设置？", "Import key settings?"),
            message: L("将写入 API Key 与相关设置（非空 Key 覆盖本地）。不含聊天记录。", "Writes API keys and related settings (non-empty keys overwrite). No chats included."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("取消", "Cancel"), style: .cancel) { _ in
            try? FileManager.default.removeItem(at: stagingFolder)
        })
        alert.addAction(UIAlertAction(title: L("导入", "Import"), style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.setBackupBusy(true)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let summary = try ConnectsKeysTransferService.importPackage(from: url)
                    DispatchQueue.main.async {
                        self.setBackupBusy(false)
                        try? FileManager.default.removeItem(at: stagingFolder)
                        self.applyImportedSettingsToForm()
                        self.showBackupMessage(L("已导入 \(summary.keyCount) 个 API Key 及相关设置。", "Imported \(summary.keyCount) API keys and related settings."))
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.setBackupBusy(false)
                        try? FileManager.default.removeItem(at: stagingFolder)
                        self.showBackupMessage(error.localizedDescription)
                    }
                }
            }
        })
        present(alert, animated: true)
    }

    private func confirmBackupRestore(from url: URL, stagingFolder: URL) {
        let alert = UIAlertController(
            title: L("二次确认", "Confirm again"),
            message: L("请输入“恢复完整备份”以确认。", "Type RESTORE to confirm."),
            preferredStyle: .alert
        )
        alert.addTextField { $0.autocorrectionType = .no }
        alert.addAction(UIAlertAction(title: L("取消", "Cancel"), style: .cancel) { _ in
            try? FileManager.default.removeItem(at: stagingFolder)
        })
        alert.addAction(UIAlertAction(title: L("恢复", "Restore"), style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            let confirmWord = SettingsManager.shared.appLanguage == .en ? "RESTORE" : "恢复完整备份"
        guard alert.textFields?.first?.text == confirmWord else {
                try? FileManager.default.removeItem(at: stagingFolder)
                self.showBackupMessage(L("确认文字不匹配，未恢复。", "Confirmation text did not match — nothing restored."))
                return
            }
            self.setBackupBusy(true)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    _ = try ConnectsBackupService.importBackup(from: url)
                    DispatchQueue.main.async {
                        self.setBackupBusy(false)
                        try? FileManager.default.removeItem(at: stagingFolder)
                        self.applyImportedSettingsToForm()
                        self.showBackupMessage(L("完整备份已恢复。", "Full backup restored."))
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.setBackupBusy(false)
                        try? FileManager.default.removeItem(at: stagingFolder)
                        self.showBackupMessage(error.localizedDescription)
                    }
                }
            }
        })
        present(alert, animated: true)
    }

    private func applyImportedSettingsToForm() {
        appearanceControl.selectedSegmentIndex = SettingsManager.shared.appearanceMode == .light ? 0 : 1
        fontSizeControl.selectedSegmentIndex = SettingsManager.shared.chatFontSizeIndex
        keepScreenOnSwitch.isOn = SettingsManager.shared.keepScreenOn
        if let idx = ReasoningEffortLevel.allCases.firstIndex(of: SettingsManager.shared.reasoningEffort) {
            reasoningEffortControl.selectedSegmentIndex = idx
        }
        renderDebugSwitch.isOn = SettingsManager.shared.renderDebugOverlayEnabled
        turnContextBarSwitch.isOn = SettingsManager.shared.turnContextBarEnabled
        deepseekField.text = SettingsManager.shared.deepseekAPIKey
        kimiField.text = SettingsManager.shared.kimiAPIKey
        dashscopeField.text = SettingsManager.shared.dashscopeAPIKey
        zhipuField.text = SettingsManager.shared.zhipuAPIKey
        doubaoField.text = SettingsManager.shared.doubaoAPIKey
        minimaxField.text = SettingsManager.shared.minimaxAPIKey
        stepfunField.text = SettingsManager.shared.stepfunAPIKey
        hunyuanField.text = SettingsManager.shared.hunyuanAPIKey
        yiField.text = SettingsManager.shared.yiAPIKey
        siliconflowField.text = SettingsManager.shared.siliconflowAPIKey
        doubaoEndpointField.text = SettingsManager.shared.doubaoEndpointID
        kimiCNSwitch.isOn = SettingsManager.shared.kimiUseChinaEndpoint
        qwenCNSwitch.isOn = SettingsManager.shared.qwenUseChinaEndpoint
        reloadBYOKRows()
        modelVisibility.reload()
        ProjectStore.shared.reloadAfterBackupImport()
    }

    private func setBackupBusy(_ busy: Bool) {
        backupBusy = busy
        let buttons = [
            exportBackupButton, importBackupButton,
            exportChatTransferButton, importChatTransferButton,
            exportKeysButton, importKeysButton,
        ]
        for button in buttons { button.isEnabled = !busy }
        if busy {
            let indicator = UIActivityIndicatorView(style: .medium)
            indicator.startAnimating()
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: indicator)
        } else {
            navigationItem.rightBarButtonItem = doneBarButton
        }
    }

    private func showBackupMessage(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("好", "OK"), style: .default))
        present(alert, animated: true)
    }

    private static let backupStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
