import UIKit

struct ConnectsMenuItem {
    let title: String
    var icon: ActionIconFactory.Kind? = nil
    var customImage: UIImage? = nil
    var isDestructive: Bool = false
    var isSelected: Bool = false
    /// Draw a section divider under this row (e.g. after「新建文件」).
    var endsSection: Bool = false
    /// Optional long-press (e.g. file rename / delete). Tap still runs `handler`.
    var longPressHandler: (() -> Void)? = nil
    let handler: () -> Void
}

struct ConnectsMenuHeaderAction {
    let icon: ActionIconFactory.Kind
    let accessibilityLabel: String
    let handler: () -> Void
}

/// ChatGPT-style floating menu — light/dark, icon rows, soft elevation.
enum ConnectsMenu {
    static func present(from host: UIViewController,
                        title: String? = nil,
                        items: [ConnectsMenuItem],
                        sourceView: UIView? = nil,
                        sourceRect: CGRect? = nil,
                        barButtonItem: UIBarButtonItem? = nil,
                        preferAbove: Bool = false,
                        preferVertical: Bool = false,
                        maxHeight: CGFloat? = nil,
                        menuWidth: CGFloat? = nil,
                        titleTap: (() -> Void)? = nil,
                        headerTrailingActions: [ConnectsMenuHeaderAction] = []) {
        // Allow empty file list when header actions are present (empty workspace).
        guard !items.isEmpty || title != nil || !headerTrailingActions.isEmpty else { return }

        // Capture in window space *before* the modal covers the hierarchy.
        let windowRect = resolveAnchorWindowRect(
            barButtonItem: barButtonItem,
            sourceView: sourceView,
            sourceRect: sourceRect,
            host: host
        )

        let menu = ConnectsMenuController(
            titleText: title,
            items: items,
            titleTap: titleTap,
            headerTrailingActions: headerTrailingActions
        )
        menu.modalPresentationStyle = .overFullScreen
        menu.modalTransitionStyle = .crossDissolve
        menu.anchorWindowRect = windowRect
        menu.preferAbove = preferAbove
        menu.preferVertical = preferVertical
        menu.maxMenuHeight = maxHeight
        menu.preferredMenuWidth = menuWidth
        // Child VCs in the drawer / split shell need a presenter that can actually present.
        topPresenter(from: host).present(menu, animated: false)
    }

    /// Resolve a stable window-space rect for the trigger control.
    private static func resolveAnchorWindowRect(
        barButtonItem: UIBarButtonItem?,
        sourceView: UIView?,
        sourceRect: CGRect?,
        host: UIViewController
    ) -> CGRect? {
        if let item = barButtonItem, let rect = windowRect(for: item) {
            return rect
        }
        if let src = sourceView, src.window != nil || src.superview != nil {
            let local = sourceRect ?? src.bounds
            var rect = src.convert(local, to: nil)
            // Full-panel anchors (reader / chat host) are useless — pin to a trailing chip.
            if rect.width > 160 || rect.height > 96 {
                rect = CGRect(
                    x: rect.maxX - 44,
                    y: rect.minY + 6,
                    width: 44,
                    height: 36
                )
            }
            // Inflate hairline / zero-size rects so placement still has a real midX.
            if rect.width < 8 || rect.height < 8 {
                rect = rect.insetBy(dx: -max(0, (24 - rect.width) / 2),
                                    dy: -max(0, (28 - rect.height) / 2))
            }
            if rect.width > 0.5, rect.height > 0.5 { return rect }
        }
        // Last resort: study / chat trailing chrome (⋯ / clock live here).
        if let nav = host.navigationController?.navigationBar ?? host.navigationItem.titleView?.superview {
            let bar = nav.convert(nav.bounds, to: nil)
            return CGRect(x: bar.maxX - 52, y: bar.midY - 18, width: 44, height: 36)
        }
        if let window = host.view.window ?? UIApplication.connectsKeyWindow {
            let safe = window.safeAreaInsets
            return CGRect(
                x: window.bounds.width - safe.right - 56,
                y: safe.top + 8,
                width: 44,
                height: 36
            )
        }
        return nil
    }

    private static func windowRect(for item: UIBarButtonItem) -> CGRect? {
        if let custom = item.customView, custom.bounds.width > 1 {
            return custom.convert(custom.bounds, to: nil)
        }
        if let view = item.value(forKey: "view") as? UIView {
            // Private UIKit view can exist before layout — wait for a real frame.
            if view.bounds.width > 1, view.bounds.height > 1 {
                view.layoutIfNeeded()
                return view.convert(view.bounds, to: nil)
            }
            // Walk to a visible descendant (common for UIBarButtonItem system wrappers).
            if let hit = view.subviews.first(where: { $0.bounds.width > 8 && $0.bounds.height > 8 }) {
                return hit.convert(hit.bounds, to: nil)
            }
        }
        return nil
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
            // Don't stack under an already-visible ConnectsMenu.
            if presented is ConnectsMenuController { break }
            candidate = presented
        }
        return candidate
    }
}

private final class ConnectsMenuController: UIViewController {
    private let titleText: String?
    private let items: [ConnectsMenuItem]
    private let titleTap: (() -> Void)?
    private let headerTrailingActions: [ConnectsMenuHeaderAction]
    var anchorWindowRect: CGRect?
    var preferAbove = false
    /// Kept for API compatibility; positioning is always vertical under/over the anchor.
    var preferVertical = false
    var maxMenuHeight: CGFloat?
    var preferredMenuWidth: CGFloat?

    private let dimView = UIControl()
    private let card = UIView()
    private let clip = UIView()
    private let stack = UIStackView()
    private var cardWidth: NSLayoutConstraint!
    private var cardLeading: NSLayoutConstraint!
    private var cardTop: NSLayoutConstraint!
    private var clipBottomToCard: NSLayoutConstraint!
    private var scrollView: UIScrollView?
    private var rows: [MenuRowView] = []
    private var titleLabel: UILabel?
    private var sectionLines: [UIView] = []
    private var headerActionButtons: [UIButton] = []

    init(titleText: String?,
         items: [ConnectsMenuItem],
         titleTap: (() -> Void)? = nil,
         headerTrailingActions: [ConnectsMenuHeaderAction] = []) {
        self.titleText = titleText
        self.items = items
        self.titleTap = titleTap
        self.headerTrailingActions = headerTrailingActions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        dimView.translatesAutoresizingMaskIntoConstraints = false
        dimView.addTarget(self, action: #selector(dismissMenu), for: .touchUpInside)
        view.addSubview(dimView)

        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 12
        view.addSubview(card)

        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.layer.cornerRadius = 12
        clip.clipsToBounds = true
        card.addSubview(clip)

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(stack)

        cardWidth = card.widthAnchor.constraint(equalToConstant: preferredMenuWidth ?? 244)
        cardLeading = card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24)
        cardTop = card.topAnchor.constraint(equalTo: view.topAnchor, constant: 80)
        clipBottomToCard = clip.bottomAnchor.constraint(equalTo: card.bottomAnchor)

        NSLayoutConstraint.activate([
            dimView.topAnchor.constraint(equalTo: view.topAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            clip.topAnchor.constraint(equalTo: card.topAnchor),
            clipBottomToCard,
            clip.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            stack.topAnchor.constraint(equalTo: clip.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: clip.bottomAnchor, constant: -5),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),

            cardWidth, cardLeading, cardTop
        ])

        buildRows()
        installScrollIfNeeded()
        applyTheme()
        card.alpha = 0
        card.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
        dimView.alpha = 0

        NotificationCenter.default.addObserver(
            self, selector: #selector(applyTheme), name: .themeDidChange, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        view.layoutIfNeeded()
        positionCard()
        scrollSelectedRowIntoViewIfNeeded()
        UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut]) {
            self.dimView.alpha = 1
            self.card.alpha = 1
            self.card.transform = .identity
        }
    }

    private func scrollSelectedRowIntoViewIfNeeded() {
        guard let scroll = scrollView,
              let idx = items.firstIndex(where: { $0.isSelected }),
              rows.indices.contains(idx) else { return }
        let rect = rows[idx].convert(rows[idx].bounds, to: scroll)
        scroll.scrollRectToVisible(rect.insetBy(dx: 0, dy: -36), animated: false)
    }

    private func installScrollIfNeeded() {
        // Cap tall menus so folders with many files stay usable.
        let screenH = view.bounds.height > 1 ? view.bounds.height : UIScreen.main.bounds.height
        let maxH = maxMenuHeight ?? min(440, max(220, screenH * 0.58))
        view.layoutIfNeeded()
        let width = cardWidth.constant
        let contentH = stack.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height + 10
        guard contentH > maxH + 1 else { return }

        clipBottomToCard.isActive = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = true
        scroll.alwaysBounceVertical = true
        card.addSubview(scroll)

        clip.removeFromSuperview()
        scroll.addSubview(clip)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: card.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: maxH),

            clip.topAnchor.constraint(equalTo: scroll.topAnchor),
            clip.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            clip.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            clip.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            clip.heightAnchor.constraint(equalToConstant: contentH)
        ])
        scrollView = scroll
        // Remember resolved cap for positionCard().
        maxMenuHeight = maxH
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.positionCard() })
    }

    @objc private func applyTheme() {
        let c = DSTheme.c
        let dark = ThemeManager.shared.mode == .dark

        dimView.backgroundColor = UIColor.black.withAlphaComponent(dark ? 0.22 : 0.10)
        card.backgroundColor = dark
            ? UIColor(red: 50/255, green: 50/255, blue: 54/255, alpha: 1)
            : UIColor(red: 255/255, green: 255/255, blue: 255/255, alpha: 1)
        clip.backgroundColor = card.backgroundColor
        card.layer.borderWidth = dark ? 0.5 : 1
        card.layer.borderColor = dark
            ? UIColor.white.withAlphaComponent(0.10).cgColor
            : UIColor.black.withAlphaComponent(0.08).cgColor
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = dark ? 0.48 : 0.14
        card.layer.shadowRadius = dark ? 20 : 14
        card.layer.shadowOffset = CGSize(width: 0, height: 8)
        card.clipsToBounds = false

        titleLabel?.textColor = c.textTertiary
        for btn in headerActionButtons {
            btn.tintColor = c.textPrimary
        }
        for line in sectionLines {
            line.backgroundColor = dark
                ? UIColor.white.withAlphaComponent(0.09)
                : UIColor.black.withAlphaComponent(0.07)
        }
        rows.forEach { $0.applyTheme(c) }
    }

    private func buildRows() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows.removeAll()
        sectionLines.removeAll()
        headerActionButtons.removeAll()
        titleLabel = nil

        if let raw = titleText?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let label = UILabel()
            label.text = raw
            label.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let wrap = UIView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(label)

            let trailingStack = UIStackView()
            trailingStack.axis = .horizontal
            trailingStack.spacing = 2
            trailingStack.alignment = .center
            trailingStack.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(trailingStack)

            for (idx, action) in headerTrailingActions.enumerated() {
                let btn = UIButton(type: .system)
                btn.translatesAutoresizingMaskIntoConstraints = false
                btn.setImage(ActionIconFactory.image(action.icon, pointSize: ActionIconFactory.menuGlyph), for: .normal)
                btn.accessibilityLabel = action.accessibilityLabel
                btn.tag = idx
                btn.addTarget(self, action: #selector(headerActionTapped(_:)), for: .touchUpInside)
                trailingStack.addArrangedSubview(btn)
                NSLayoutConstraint.activate([
                    btn.widthAnchor.constraint(equalToConstant: 32),
                    btn.heightAnchor.constraint(equalToConstant: 32)
                ])
                headerActionButtons.append(btn)
            }

            if titleTap != nil {
                let tap = UITapGestureRecognizer(target: self, action: #selector(titleHeaderTapped))
                label.isUserInteractionEnabled = true
                label.addGestureRecognizer(tap)
            }

            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 6),
                label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -6),
                label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 14),
                trailingStack.centerYAnchor.constraint(equalTo: label.centerYAnchor),
                trailingStack.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -8),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingStack.leadingAnchor, constant: -8),
                wrap.heightAnchor.constraint(greaterThanOrEqualToConstant: 36)
            ])
            stack.addArrangedSubview(wrap)
            titleLabel = label
            if !items.isEmpty || !headerTrailingActions.isEmpty {
                stack.addArrangedSubview(makeSectionLine())
            }
        }

        for (idx, item) in items.enumerated() {
            if item.isDestructive, idx > 0, !items[idx - 1].isDestructive {
                stack.addArrangedSubview(makeSectionLine())
            }
            let row = MenuRowView(item: item, index: idx)
            row.onTap = { [weak self] i in self?.selectItem(at: i) }
            row.onLongPress = { [weak self] i in self?.longPressItem(at: i) }
            stack.addArrangedSubview(row)
            rows.append(row)
            if item.endsSection {
                stack.addArrangedSubview(makeSectionLine())
            }
        }
    }

    @objc private func titleHeaderTapped() {
        guard let titleTap else { return }
        dismissThen(titleTap)
    }

    @objc private func headerActionTapped(_ sender: UIButton) {
        guard headerTrailingActions.indices.contains(sender.tag) else { return }
        let handler = headerTrailingActions[sender.tag].handler
        dismissThen(handler)
    }

    private func dismissThen(_ handler: @escaping () -> Void) {
        UIView.animate(withDuration: 0.12, animations: {
            self.dimView.alpha = 0
            self.card.alpha = 0
            self.card.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
        }, completion: { _ in
            self.dismiss(animated: false) { handler() }
        })
    }

    private func makeSectionLine() -> UIView {
        let line = UIView()
        line.translatesAutoresizingMaskIntoConstraints = false
        let h = 1 / UIScreen.main.scale
        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 12),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -12),
            line.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 5),
            line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -5),
            line.heightAnchor.constraint(equalToConstant: h),
            wrap.heightAnchor.constraint(equalToConstant: 11)
        ])
        sectionLines.append(line)
        return wrap
    }

    private func selectItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        let handler = items[index].handler
        dismissThen(handler)
    }

    private func longPressItem(at index: Int) {
        guard items.indices.contains(index),
              let handler = items[index].longPressHandler else { return }
        dismissThen(handler)
    }

    @objc private func dismissMenu() {
        UIView.animate(withDuration: 0.12, animations: {
            self.dimView.alpha = 0
            self.card.alpha = 0
            self.card.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
        }, completion: { _ in
            self.dismiss(animated: false)
        })
    }

    /// Unified placement: below the trigger when possible, otherwise above;
    /// trailing-align when the trigger is on the right half, else leading-align.
    private func positionCard() {
        let margin: CGFloat = 12
        let gap: CGFloat = 6
        let width = cardWidth.constant
        cardWidth.constant = width
        view.layoutIfNeeded()

        let cardH: CGFloat
        if let scroll = scrollView {
            cardH = scroll.bounds.height > 1 ? scroll.bounds.height : (maxMenuHeight ?? 280)
        } else {
            cardH = max(44, card.systemLayoutSizeFitting(
                CGSize(width: width, height: 0),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height)
        }

        let safe = view.safeAreaInsets
        let minX = margin + safe.left
        let maxX = max(minX, view.bounds.width - width - margin - safe.right)
        let minY = margin + safe.top
        let maxY = max(minY, view.bounds.height - cardH - margin - safe.bottom)

        var x: CGFloat
        var y: CGFloat

        if let wr = anchorWindowRect {
            let rect = view.convert(wr, from: nil)
            let belowY = rect.maxY + gap
            let aboveY = rect.minY - cardH - gap
            let fitsBelow = belowY <= maxY
            let fitsAbove = aboveY >= minY

            if preferAbove, fitsAbove {
                y = aboveY
            } else if fitsBelow {
                y = belowY
            } else if fitsAbove {
                y = aboveY
            } else {
                y = min(max(minY, belowY), maxY)
            }

            // Center-ish triggers (file title) → center the card under the control.
            // Right-half → trailing edges match; left-half → leading edges match.
            let centerBand = max(120, view.bounds.width * 0.22)
            if abs(rect.midX - view.bounds.midX) <= centerBand {
                x = rect.midX - width / 2
            } else if rect.midX >= view.bounds.midX {
                x = rect.maxX - width
            } else {
                x = rect.minX
            }
        } else {
            // Fallback matches study chrome: under the trailing nav cluster.
            x = maxX
            y = minY + 4
        }

        cardLeading.constant = min(max(minX, x), maxX)
        cardTop.constant = min(max(minY, y), maxY)
        view.layoutIfNeeded()
    }
}

// MARK: - Row

private final class MenuRowView: UIView {
    var onTap: ((Int) -> Void)?
    var onLongPress: ((Int) -> Void)?
    private let item: ConnectsMenuItem
    private let index: Int
    private let hit = UIButton(type: .custom)
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let checkView = UIImageView()
    private let highlight = UIView()

    init(item: ConnectsMenuItem, index: Int) {
        self.item = item
        self.index = index
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        highlight.translatesAutoresizingMaskIntoConstraints = false
        highlight.layer.cornerRadius = 8
        highlight.isUserInteractionEnabled = false
        highlight.alpha = 0
        addSubview(highlight)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconView.isHidden = item.icon == nil && item.customImage == nil
        if let image = item.customImage {
            iconView.image = image
        } else if let kind = item.icon {
            iconView.image = ActionIconFactory.image(kind, pointSize: ActionIconFactory.menuGlyph)
        }
        addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = item.title
        titleLabel.font = UIFont.systemFont(ofSize: 15, weight: .regular)
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        checkView.translatesAutoresizingMaskIntoConstraints = false
        checkView.contentMode = .center
        checkView.isHidden = !item.isSelected
        if item.isSelected {
            let label = UILabel()
            label.text = "✓"
            label.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
            label.translatesAutoresizingMaskIntoConstraints = false
            checkView.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: checkView.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: checkView.centerYAnchor)
            ])
            checkView.accessibilityLabel = "selected"
        }
        addSubview(checkView)

        hit.translatesAutoresizingMaskIntoConstraints = false
        hit.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        hit.addTarget(self, action: #selector(down), for: .touchDown)
        hit.addTarget(self, action: #selector(up), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        addSubview(hit)
        if item.longPressHandler != nil {
            let long = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
            long.minimumPressDuration = 0.45
            hit.addGestureRecognizer(long)
            accessibilityHint = "长按可重命名或删除"
        }

        let hasIcon = item.icon != nil || item.customImage != nil
        let iconW: CGFloat = hasIcon ? 22 : 0
        let leadingTitle: CGFloat = hasIcon ? 10 : 14
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 40),

            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: iconW),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: leadingTitle),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkView.leadingAnchor, constant: -8),

            checkView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            checkView.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkView.widthAnchor.constraint(equalToConstant: item.isSelected ? 16 : 0),
            checkView.heightAnchor.constraint(equalToConstant: 16),

            hit.topAnchor.constraint(equalTo: topAnchor),
            hit.bottomAnchor.constraint(equalTo: bottomAnchor),
            hit.leadingAnchor.constraint(equalTo: leadingAnchor),
            hit.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyTheme(_ c: ThemeColors) {
        if item.isDestructive {
            titleLabel.textColor = UIColor(red: 239/255, green: 68/255, blue: 68/255, alpha: 1)
            iconView.tintColor = titleLabel.textColor
        } else {
            titleLabel.textColor = c.textPrimary
            iconView.tintColor = c.textSecondary
        }
        highlight.backgroundColor = c.surfaceHover
        if let checkLabel = checkView.subviews.first as? UILabel {
            checkLabel.textColor = c.accent
        }
    }

    @objc private func down() { highlight.alpha = 1 }
    @objc private func up() { highlight.alpha = 0 }
    @objc private func tapped() { onTap?(index) }
    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        highlight.alpha = 0
        onLongPress?(index)
    }
}
