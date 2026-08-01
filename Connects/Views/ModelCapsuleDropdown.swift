import UIKit

/// Dropdown for the input-bar / nav model chip.
/// Hosted as a **window overlay** (not a modal VC) so the composer keyboard stays up.
enum ModelCapsuleDropdown {
    private static var activeOverlay: ModelCapsuleDropdownOverlay?

    static func present(from host: UIViewController,
                        anchor: UIView,
                        models: [AIModelOption],
                        selected: AIModelOption?,
                        onPick: @escaping (AIModelOption) -> Void,
                        onDismiss: (() -> Void)? = nil) {
        guard !models.isEmpty else { return }
        dismissActive(animated: false)

        host.view.layoutIfNeeded()
        anchor.superview?.layoutIfNeeded()
        anchor.layoutIfNeeded()

        guard let window = anchor.window
            ?? host.view.window
            ?? UIApplication.shared.windows.first(where: { $0.isKeyWindow }) else { return }

        let keptResponder = findFirstResponder(in: window) as? UIView

        let overlay = ModelCapsuleDropdownOverlay(
            models: models,
            selectedID: selected?.stableID,
            anchorView: anchor,
            onPick: onPick,
            onDismiss: {
                activeOverlay = nil
                if let keptResponder, !keptResponder.isFirstResponder {
                    keptResponder.becomeFirstResponder()
                }
                onDismiss?()
            }
        )
        activeOverlay = overlay
        overlay.install(in: window)

        if let keptResponder, !keptResponder.isFirstResponder {
            keptResponder.becomeFirstResponder()
        }

        // Layout + keyboard insets often settle one turn later.
        DispatchQueue.main.async {
            overlay.refreshPosition(animated: false)
            if let keptResponder, !keptResponder.isFirstResponder {
                keptResponder.becomeFirstResponder()
            }
        }
    }

    static func dismissActive(animated: Bool = true) {
        activeOverlay?.dismiss(animated: animated)
        activeOverlay = nil
    }

    private static func findFirstResponder(in view: UIView) -> UIResponder? {
        if view.isFirstResponder { return view }
        for sub in view.subviews {
            if let found = findFirstResponder(in: sub) { return found }
        }
        return nil
    }
}

private final class ModelCapsuleDropdownOverlay: UIView {
    private let models: [AIModelOption]
    private let selectedID: String?
    private weak var anchorView: UIView?
    private let onPick: (AIModelOption) -> Void
    private let onDismiss: () -> Void

    private let dim = UIControl()
    private let panel = UIView()
    private let stack = UIStackView()
    private var rowButtons: [UIButton] = []
    private var didFinish = false
    private var panelSize = CGSize(width: 200, height: 90)

    init(models: [AIModelOption],
         selectedID: String?,
         anchorView: UIView,
         onPick: @escaping (AIModelOption) -> Void,
         onDismiss: @escaping () -> Void) {
        self.models = models
        self.selectedID = selectedID
        self.anchorView = anchorView
        self.onPick = onPick
        self.onDismiss = onDismiss
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func install(in window: UIWindow) {
        // Frame-based full-window cover — avoids Auto Layout zero-bounds convert bugs.
        frame = window.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(self)

        buildChrome()
        applyTheme()
        measurePanel()
        positionPanel()

        alpha = 0
        panel.transform = CGAffineTransform(translationX: 0, y: 4).scaledBy(x: 0.98, y: 0.96)
        UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.alpha = 1
            self.panel.alpha = 1
            self.panel.transform = .identity
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(applyTheme), name: .themeDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameChanged(_:)),
            name: UIResponder.keyboardDidChangeFrameNotification,
            object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func refreshPosition(animated: Bool) {
        if let w = window { frame = w.bounds }
        measurePanel()
        positionPanel()
        if animated { layoutIfNeeded() }
    }

    private func buildChrome() {
        backgroundColor = .clear

        dim.frame = bounds
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.01)
        dim.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        addSubview(dim)

        panel.layer.cornerRadius = 14
        panel.clipsToBounds = false
        panel.alpha = 0
        addSubview(panel)

        let clip = UIView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.layer.cornerRadius = 14
        clip.clipsToBounds = true
        panel.addSubview(clip)

        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(stack)

        NSLayoutConstraint.activate([
            clip.topAnchor.constraint(equalTo: panel.topAnchor),
            clip.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            clip.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: panel.trailingAnchor),

            stack.topAnchor.constraint(equalTo: clip.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: clip.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clip.trailingAnchor)
        ])

        buildRows()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dim.frame = bounds
        positionPanel()
    }

    @objc private func keyboardFrameChanged(_ note: Notification) {
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.2
        let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt)
            ?? UIView.AnimationOptions.curveEaseInOut.rawValue
        let options = UIView.AnimationOptions(rawValue: curveRaw << 16)
        UIView.animate(withDuration: duration, delay: 0, options: [options, .beginFromCurrentState]) {
            if let w = self.window { self.frame = w.bounds }
            self.positionPanel()
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
            title.isUserInteractionEnabled = false

            let check = UIImageView(image: UIImage(systemName: "checkmark"))
            check.translatesAutoresizingMaskIntoConstraints = false
            check.contentMode = .scaleAspectFit
            check.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            check.tintColor = DSTheme.c.accent
            check.isHidden = !selected
            check.tag = 9001
            check.isUserInteractionEnabled = false

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

    @objc private func dismissTapped() {
        finish(pick: nil)
    }

    func dismiss(animated: Bool) {
        finish(pick: nil, animated: animated)
    }

    private func finish(pick: AIModelOption?, animated: Bool = true) {
        guard !didFinish else { return }
        didFinish = true
        NotificationCenter.default.removeObserver(self)
        let cleanup = {
            self.removeFromSuperview()
            if let pick = pick {
                self.onPick(pick)
            }
            self.onDismiss()
        }
        if animated {
            UIView.animate(withDuration: 0.12, animations: {
                self.alpha = 0
                self.panel.transform = CGAffineTransform(translationX: 0, y: 3).scaledBy(x: 0.98, y: 0.97)
            }, completion: { _ in cleanup() })
        } else {
            cleanup()
        }
    }

    private func measurePanel() {
        let names = models.map(\.displayName)
        let font = UIFont.systemFont(ofSize: 15, weight: .regular)
        let longest = names.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 120
        var width = max(longest + 52, 168)
        if let anchor = anchorView {
            width = max(width, anchor.bounds.width)
        }
        width = min(width, 260)
        let height = CGFloat(models.count) * 42 + 8
        panelSize = CGSize(width: width, height: height)
    }

    /// Chip rect in **this** overlay's coordinate space, via the shared window.
    private func liveAnchorRect() -> CGRect? {
        guard let anchor = anchorView,
              let hostWindow = anchor.window ?? window,
              bounds.width > 1, bounds.height > 1 else { return nil }

        // Convert through the window — never through an Auto Layout view mid-settle.
        let inWindow = anchor.convert(anchor.bounds, to: hostWindow)
        var rect = convert(inWindow, from: hostWindow)

        // If overlay == window bounds, prefer window coords directly (Catalyst-safe).
        if abs(bounds.width - hostWindow.bounds.width) < 1,
           abs(bounds.height - hostWindow.bounds.height) < 1,
           abs(frame.minX) < 1, abs(frame.minY) < 1 {
            rect = inWindow
        }

        if rect.width < 8 || rect.height < 8 {
            rect = rect.insetBy(
                dx: -max(0, (72 - rect.width) / 2),
                dy: -max(0, (32 - rect.height) / 2)
            )
        }

        guard rect.width > 4, rect.height > 4 else { return nil }
        // Reject absurd positions (e.g. still at 0,0 while chip is elsewhere).
        if rect.origin == .zero,
           let anchor = anchorView,
           anchor.frame.origin != .zero || (anchor.superview?.frame.origin != .zero) {
            // One more try: convert to self directly after forcing window layout.
            hostWindow.layoutIfNeeded()
            rect = anchor.convert(anchor.bounds, to: self)
        }
        return rect
    }

    private func positionPanel() {
        let margin: CGFloat = 10
        let gap: CGFloat = 6
        measurePanel()
        let size = panelSize

        guard let rect = liveAnchorRect() else {
            // Keep previous frame if we already placed; otherwise stay hidden until we can pin.
            if panel.frame.origin == .zero || panel.alpha < 0.01 {
                panel.isHidden = true
            }
            return
        }
        panel.isHidden = false

        let spaceAbove = rect.minY - margin
        let spaceBelow = bounds.height - rect.maxY - margin
        let placeAbove = spaceAbove >= size.height + gap || spaceAbove >= spaceBelow

        var x = rect.maxX - size.width
        var y = placeAbove ? rect.minY - size.height - gap : rect.maxY + gap

        x = min(max(margin, x), max(margin, bounds.width - size.width - margin))
        y = min(max(margin, y), max(margin, bounds.height - size.height - margin))

        panel.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        panel.layoutIfNeeded()
    }

    override var canBecomeFirstResponder: Bool { false }
}
