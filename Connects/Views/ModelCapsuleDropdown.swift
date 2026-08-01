import UIKit

/// Dropdown for the input-bar / nav model chip.
/// Always anchors to the chip in **window** space and prefers sitting **above** it
/// (composer chips live near the keyboard — hanging below lands in the wrong place).
enum ModelCapsuleDropdown {
    static func present(from host: UIViewController,
                        anchor: UIView,
                        models: [AIModelOption],
                        selected: AIModelOption?,
                        onPick: @escaping (AIModelOption) -> Void,
                        onDismiss: (() -> Void)? = nil) {
        guard !models.isEmpty else { return }
        host.view.layoutIfNeeded()
        anchor.superview?.layoutIfNeeded()
        anchor.layoutIfNeeded()

        var windowRect = anchor.convert(anchor.bounds, to: nil)
        if windowRect.width < 8 || windowRect.height < 8 {
            windowRect = windowRect.insetBy(
                dx: -max(0, (72 - windowRect.width) / 2),
                dy: -max(0, (32 - windowRect.height) / 2)
            )
        }

        let vc = ModelCapsuleDropdownController(
            models: models,
            selectedID: selected?.stableID,
            onPick: onPick,
            onDismiss: onDismiss
        )
        vc.modalPresentationStyle = .overFullScreen
        vc.modalTransitionStyle = .crossDissolve
        vc.anchorWindowRect = windowRect
        topPresenter(from: host).present(vc, animated: false)
    }

    private static func topPresenter(from host: UIViewController) -> UIViewController {
        var candidate = host
        while let parent = candidate.parent {
            candidate = parent
        }
        if let root = host.view.window?.rootViewController {
            candidate = root
        }
        while let presented = candidate.presentedViewController {
            if presented is ModelCapsuleDropdownController { break }
            candidate = presented
        }
        return candidate
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
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.12)
        dim.alpha = 0
        dim.addTarget(self, action: #selector(dismissDropdown), for: .touchUpInside)
        view.addSubview(dim)

        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.layer.cornerRadius = 14
        panel.clipsToBounds = false
        panel.alpha = 0
        panel.transform = CGAffineTransform(translationX: 0, y: 4).scaledBy(x: 0.98, y: 0.96)
        view.addSubview(panel)

        let clip = UIView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.layer.cornerRadius = 14
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

            stack.topAnchor.constraint(equalTo: clip.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: clip.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),

            panelWidth, panelLeading, panelTop
        ])

        buildRows()
        applyTheme()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyTheme), name: .themeDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        positionPanel()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        positionPanel()
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
            self.dim.alpha = 1
            self.panel.alpha = 1
            self.panel.transform = .identity
        }
    }

    @objc private func keyboardFrameChanged(_ note: Notification) {
        positionPanel()
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.2
        UIView.animate(withDuration: duration) {
            self.view.layoutIfNeeded()
        }
    }

    @objc private func applyTheme() {
        let c = DSTheme.c
        let dark = ThemeManager.shared.mode == .dark
        panel.backgroundColor = dark
            ? UIColor(red: 44/255, green: 44/255, blue: 48/255, alpha: 1)
            : UIColor.white
        panel.layer.borderWidth = 1 / UIScreen.main.scale
        panel.layer.borderColor = (dark
            ? UIColor.white.withAlphaComponent(0.10)
            : UIColor.black.withAlphaComponent(0.08)).cgColor
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = dark ? 0.35 : 0.12
        panel.layer.shadowRadius = 12
        panel.layer.shadowOffset = CGSize(width: 0, height: 6)

        for (i, btn) in rowButtons.enumerated() where models.indices.contains(i) {
            let selected = models[i].stableID == selectedID
            btn.backgroundColor = .clear
            if let title = btn.viewWithTag(9002) as? UILabel {
                title.textColor = selected ? c.accent : c.textPrimary
                title.font = UIFont.systemFont(ofSize: 15, weight: selected ? .semibold : .regular)
            }
            if let check = btn.viewWithTag(9001) as? UIImageView {
                check.tintColor = c.accent
                check.isHidden = !selected
            }
        }
    }

    private func buildRows() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowButtons.removeAll()

        for (idx, model) in models.enumerated() {
            let selected = model.stableID == selectedID
            let row = UIButton(type: .custom)
            row.contentHorizontalAlignment = .fill
            row.tag = idx
            row.addTarget(self, action: #selector(rowTapped(_:)), for: .touchUpInside)
            row.addTarget(self, action: #selector(rowDown(_:)), for: .touchDown)
            row.addTarget(self, action: #selector(rowUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])

            let title = UILabel()
            title.translatesAutoresizingMaskIntoConstraints = false
            title.text = model.displayName
            title.font = UIFont.systemFont(ofSize: 15, weight: selected ? .semibold : .regular)
            title.textColor = selected ? DSTheme.c.accent : DSTheme.c.textPrimary
            title.lineBreakMode = .byTruncatingTail
            title.tag = 9002

            let check = UIImageView(image: UIImage(systemName: "checkmark"))
            check.translatesAutoresizingMaskIntoConstraints = false
            check.contentMode = .scaleAspectFit
            check.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            check.tintColor = DSTheme.c.accent
            check.isHidden = !selected
            check.tag = 9001

            row.addSubview(title)
            row.addSubview(check)
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 42),
                title.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
                title.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                title.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -8),
                check.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
                check.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                check.widthAnchor.constraint(equalToConstant: 14),
                check.heightAnchor.constraint(equalToConstant: 14)
            ])

            stack.addArrangedSubview(row)
            rowButtons.append(row)
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
        finish(pick: models[idx])
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
            self.panel.transform = CGAffineTransform(translationX: 0, y: 3).scaledBy(x: 0.98, y: 0.97)
        }, completion: { _ in
            self.dismiss(animated: false) {
                if let pick = pick {
                    self.onPick(pick)
                }
                self.onDismiss?()
            }
        })
    }

    private func keyboardTopY() -> CGFloat {
        let screen = view.window?.bounds ?? UIScreen.main.bounds
        // Prefer live keyboard window if present.
        for window in UIApplication.shared.windows where window !== view.window {
            let name = NSStringFromClass(type(of: window))
            if name.contains("Keyboard") || name.contains("UIRemoteKeyboard") {
                let frame = window.convert(window.bounds, to: view)
                if frame.height > 40, frame.minY < screen.height - 20 {
                    return frame.minY
                }
            }
        }
        return view.bounds.height
    }

    private func positionPanel() {
        let margin: CGFloat = 10
        let names = models.map(\.displayName)
        let font = UIFont.systemFont(ofSize: 15, weight: .regular)
        let longest = names.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 120
        var width = max(longest + 52, 168)
        if let wr = anchorWindowRect {
            width = max(width, wr.width)
        }
        width = min(width, min(260, view.bounds.width - margin * 2))
        panelWidth.constant = width
        view.layoutIfNeeded()

        let panelH = max(40, panel.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height)

        let usableBottom = min(view.bounds.height, keyboardTopY()) - margin
        var x: CGFloat
        var y: CGFloat
        if let wr = anchorWindowRect {
            let rect = view.convert(wr, from: nil)
            // Align trailing edge with the chip (chip sits on the right of the composer).
            x = rect.maxX - width
            let spaceBelow = usableBottom - rect.maxY - 6
            let spaceAbove = rect.minY - margin - 6
            let placeAbove = spaceBelow < panelH + 4 || spaceAbove >= spaceBelow
            if placeAbove {
                y = rect.minY - panelH - 6
            } else {
                y = rect.maxY + 6
            }
        } else {
            x = (view.bounds.width - width) * 0.5
            y = usableBottom - panelH - 8
        }

        x = min(max(margin, x), view.bounds.width - width - margin)
        y = min(max(margin, y), usableBottom - panelH)
        panelLeading.constant = x
        panelTop.constant = y
    }
}
