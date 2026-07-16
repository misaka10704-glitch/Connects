import UIKit

struct ConnectsMenuItem {
    let title: String
    var icon: ActionIconFactory.Kind? = nil
    var customImage: UIImage? = nil
    var isDestructive: Bool = false
    var isSelected: Bool = false
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
                        menuWidth: CGFloat? = nil) {
        guard !items.isEmpty else { return }

        // Capture in window space *before* the modal covers the hierarchy.
        var windowRect: CGRect?
        if let item = barButtonItem,
           let itemView = item.value(forKey: "view") as? UIView {
            windowRect = itemView.convert(itemView.bounds, to: nil)
        } else if let src = sourceView {
            let r = sourceRect ?? src.bounds
            windowRect = src.convert(r, to: nil)
        }

        let menu = ConnectsMenuController(titleText: title, items: items)
        menu.modalPresentationStyle = .overFullScreen
        menu.modalTransitionStyle = .crossDissolve
        menu.anchorWindowRect = windowRect
        menu.preferAbove = preferAbove
        menu.preferVertical = preferVertical
        menu.maxMenuHeight = maxHeight
        menu.preferredMenuWidth = menuWidth
        host.present(menu, animated: false)
    }
}

private final class ConnectsMenuController: UIViewController {
    private let titleText: String?
    private let items: [ConnectsMenuItem]
    var anchorWindowRect: CGRect?
    var preferAbove = false
    /// List / full-width rows: always place above/below the touch, never into the sibling pane.
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

    init(titleText: String?, items: [ConnectsMenuItem]) {
        self.titleText = titleText
        self.items = items
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
        UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut]) {
            self.dimView.alpha = 1
            self.card.alpha = 1
            self.card.transform = .identity
        }
    }

    private func installScrollIfNeeded() {
        guard let maxH = maxMenuHeight, maxH > 80 else { return }
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
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.positionCard() })
    }

    @objc private func applyTheme() {
        let c = DSTheme.c
        let dark = ThemeManager.shared.mode == .dark

        dimView.backgroundColor = UIColor.black.withAlphaComponent(dark ? 0.22 : 0.10)
        // Elevated panel — ChatGPT: slightly lifted over page chrome.
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
        titleLabel = nil

        if let raw = titleText?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let label = UILabel()
            label.text = raw
            label.font = UIFont.systemFont(ofSize: 12, weight: .medium)
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            let wrap = UIView()
            wrap.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 8),
                label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -6),
                label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 14),
                label.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -14),
                wrap.heightAnchor.constraint(greaterThanOrEqualToConstant: 30)
            ])
            stack.addArrangedSubview(wrap)
            titleLabel = label
            stack.addArrangedSubview(makeSectionLine())
        }

        for (idx, item) in items.enumerated() {
            // ChatGPT: hairline only before destructive cluster.
            if item.isDestructive, idx > 0, !items[idx - 1].isDestructive {
                stack.addArrangedSubview(makeSectionLine())
            }
            let row = MenuRowView(item: item, index: idx)
            row.onTap = { [weak self] i in self?.selectItem(at: i) }
            stack.addArrangedSubview(row)
            rows.append(row)
        }
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
        UIView.animate(withDuration: 0.12, animations: {
            self.dimView.alpha = 0
            self.card.alpha = 0
            self.card.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
        }, completion: { _ in
            self.dismiss(animated: false) { handler() }
        })
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

    private func positionCard() {
        let margin: CGFloat = 14
        let width = cardWidth.constant
        cardWidth.constant = width
        view.layoutIfNeeded()
        let cardH: CGFloat
        if let scroll = scrollView {
            cardH = scroll.bounds.height
        } else {
            cardH = max(44, card.systemLayoutSizeFitting(
                CGSize(width: width, height: 0),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height)
        }

        var x: CGFloat
        var y: CGFloat
        if let wr = anchorWindowRect {
            let rect = view.convert(wr, from: nil)
            let spaceBelow = view.bounds.height - rect.maxY - margin
            let spaceAbove = rect.minY - margin
            let spaceRight = view.bounds.width - rect.maxX - margin
            // Wide anchors (table rows) or explicit vertical → never side-dock into another pane.
            let forceVertical = preferVertical || preferAbove || rect.width > 96
            let nearBottom = preferAbove || rect.midY > view.bounds.height * 0.62 || spaceBelow < cardH + 12

            if !forceVertical, spaceRight >= width + 8, !nearBottom {
                x = rect.maxX + 8
                y = rect.midY - 22
            } else if nearBottom, spaceAbove >= cardH + 8 {
                x = min(max(margin, rect.midX - width * 0.5), view.bounds.width - width - margin)
                // Clamp toward the touch so wide rows don't jump to the far left.
                x = min(max(margin, rect.minX), view.bounds.width - width - margin)
                y = rect.minY - cardH - 8
            } else if spaceBelow >= cardH + 8 {
                x = min(max(margin, rect.minX), view.bounds.width - width - margin)
                y = rect.maxY + 8
            } else {
                x = min(max(margin, rect.minX), view.bounds.width - width - margin)
                y = max(margin, min(rect.minY - cardH - 8, view.bounds.height - cardH - margin))
            }
        } else {
            x = (view.bounds.width - width) * 0.5
            y = view.bounds.height * 0.26
        }

        x = min(max(margin, x), view.bounds.width - width - margin)
        y = min(max(margin, y), view.bounds.height - cardH - margin)
        cardLeading.constant = x
        cardTop.constant = y
        view.layoutIfNeeded()
    }
}

// MARK: - Row

private final class MenuRowView: UIView {
    var onTap: ((Int) -> Void)?
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
            iconView.image = ActionIconFactory.image(kind, pointSize: 15)
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
            // Simple checkmark drawn as text for crisp iOS 12 rendering.
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
}
