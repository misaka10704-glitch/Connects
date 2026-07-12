import UIKit

/// Dropdown that hangs from the nav model capsule — not the generic ConnectsMenu.
enum ModelCapsuleDropdown {
    static func present(from host: UIViewController,
                        anchor: UIView,
                        models: [AIModelOption],
                        selected: AIModelOption?,
                        onPick: @escaping (AIModelOption) -> Void,
                        onDismiss: (() -> Void)? = nil) {
        guard !models.isEmpty else { return }
        let vc = ModelCapsuleDropdownController(
            models: models,
            selectedID: selected?.stableID,
            onPick: onPick,
            onDismiss: onDismiss
        )
        vc.modalPresentationStyle = .overFullScreen
        vc.modalTransitionStyle = .crossDissolve
        vc.anchorWindowRect = anchor.convert(anchor.bounds, to: nil)
        host.present(vc, animated: false)
    }
}

private final class ModelCapsuleDropdownController: UIViewController {
    private let models: [AIModelOption]
    private let selectedID: String?
    private let onPick: (AIModelOption) -> Void
    private let onDismiss: (() -> Void)?
    var anchorWindowRect: CGRect?

    private let dim = UIControl()
    private let panel = UIView()
    private let stack = UIStackView()
    private var panelWidth: NSLayoutConstraint!
    private var panelLeading: NSLayoutConstraint!
    private var panelTop: NSLayoutConstraint!
    private var rowButtons: [UIButton] = []
    private var didFinish = false

    init(models: [AIModelOption],
         selectedID: String?,
         onPick: @escaping (AIModelOption) -> Void,
         onDismiss: (() -> Void)?) {
        self.models = models
        self.selectedID = selectedID
        self.onPick = onPick
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        dim.translatesAutoresizingMaskIntoConstraints = false
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.08)
        dim.alpha = 0
        dim.addTarget(self, action: #selector(dismissDropdown), for: .touchUpInside)
        view.addSubview(dim)

        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.layer.cornerRadius = 16
        panel.clipsToBounds = false
        panel.alpha = 0
        panel.transform = CGAffineTransform(translationX: 0, y: -6).scaledBy(x: 0.98, y: 0.96)
        view.addSubview(panel)

        let clip = UIView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.layer.cornerRadius = 16
        clip.clipsToBounds = true
        panel.addSubview(clip)

        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(stack)

        panelWidth = panel.widthAnchor.constraint(equalToConstant: 220)
        panelLeading = panel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40)
        panelTop = panel.topAnchor.constraint(equalTo: view.topAnchor, constant: 60)

        NSLayoutConstraint.activate([
            dim.topAnchor.constraint(equalTo: view.topAnchor),
            dim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            clip.topAnchor.constraint(equalTo: panel.topAnchor),
            clip.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            clip.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: panel.trailingAnchor),

            stack.topAnchor.constraint(equalTo: clip.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: clip.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),

            panelWidth, panelLeading, panelTop
        ])

        buildRows()
        applyTheme()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyTheme), name: .themeDidChange, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        positionPanel()
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
            self.dim.alpha = 1
            self.panel.alpha = 1
            self.panel.transform = .identity
        }
    }

    @objc private func applyTheme() {
        let c = DSTheme.c
        let dark = ThemeManager.shared.mode == .dark
        // Match the nav capsule surface language.
        panel.backgroundColor = dark
            ? UIColor(red: 48/255, green: 48/255, blue: 52/255, alpha: 1)
            : UIColor(red: 255/255, green: 255/255, blue: 255/255, alpha: 1)
        panel.layer.borderWidth = 1 / UIScreen.main.scale
        panel.layer.borderColor = (dark
            ? UIColor.white.withAlphaComponent(0.12)
            : UIColor.black.withAlphaComponent(0.10)).cgColor
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = dark ? 0.40 : 0.14
        panel.layer.shadowRadius = 16
        panel.layer.shadowOffset = CGSize(width: 0, height: 8)

        for (i, btn) in rowButtons.enumerated() where models.indices.contains(i) {
            let selected = models[i].stableID == selectedID
            btn.setTitleColor(selected ? c.accent : c.textPrimary, for: .normal)
            btn.backgroundColor = .clear
        }
    }

    private func buildRows() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowButtons.removeAll()

        for (idx, model) in models.enumerated() {
            let selected = model.stableID == selectedID
            let btn = UIButton(type: .custom)
            btn.contentHorizontalAlignment = .left
            btn.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: selected ? .semibold : .regular)
            btn.contentEdgeInsets = UIEdgeInsets(top: 11, left: 16, bottom: 11, right: 16)
            let title = selected ? "\(model.displayName)  ✓" : model.displayName
            btn.setTitle(title, for: .normal)
            btn.tag = idx
            btn.addTarget(self, action: #selector(rowTapped(_:)), for: .touchUpInside)
            btn.addTarget(self, action: #selector(rowDown(_:)), for: .touchDown)
            btn.addTarget(self, action: #selector(rowUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
            stack.addArrangedSubview(btn)
            rowButtons.append(btn)
        }
    }

    @objc private func rowDown(_ sender: UIButton) {
        sender.backgroundColor = DSTheme.c.surfaceHover
    }

    @objc private func rowUp(_ sender: UIButton) {
        sender.backgroundColor = .clear
    }

    @objc private func rowTapped(_ sender: UIButton) {
        let idx = sender.tag
        guard models.indices.contains(idx) else { return }
        let model = models[idx]
        finish(pick: model)
    }

    @objc private func dismissDropdown() {
        finish(pick: nil)
    }

    private func finish(pick: AIModelOption?) {
        guard !didFinish else { return }
        didFinish = true
        UIView.animate(withDuration: 0.12, animations: {
            self.dim.alpha = 0
            self.panel.alpha = 0
            self.panel.transform = CGAffineTransform(translationX: 0, y: -4).scaledBy(x: 0.98, y: 0.97)
        }, completion: { _ in
            self.dismiss(animated: false) {
                if let pick = pick {
                    self.onPick(pick)
                }
                self.onDismiss?()
            }
        })
    }

    private func positionPanel() {
        let margin: CGFloat = 12
        // Width tracks capsule, with a comfortable minimum for long names.
        var width: CGFloat = 200
        if let wr = anchorWindowRect {
            width = max(wr.width + 36, 200)
        }
        width = min(width, min(280, view.bounds.width - margin * 2))
        panelWidth.constant = width
        view.layoutIfNeeded()

        let panelH = max(40, panel.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height)

        var x: CGFloat
        var y: CGFloat
        if let wr = anchorWindowRect {
            let rect = view.convert(wr, from: nil)
            // Hang centered under the capsule.
            x = rect.midX - width * 0.5
            y = rect.maxY + 6
        } else {
            x = (view.bounds.width - width) * 0.5
            y = 72
        }
        x = min(max(margin, x), view.bounds.width - width - margin)
        y = min(max(margin, y), view.bounds.height - panelH - margin)
        panelLeading.constant = x
        panelTop.constant = y
        view.layoutIfNeeded()
    }
}
