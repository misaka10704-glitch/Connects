import UIKit

/// Breakdown sheet for what occupies the model context window.
final class ContextUsageDetailViewController: UIViewController, ThemeRefreshable {
    var onCompact: (() -> Void)?

    private let breakdown: ContextBuilder.Breakdown
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let percentLabel = UILabel()
    private let tokenLabel = UILabel()
    private let barTrack = UIView()
    private let legendStack = UIStackView()
    private let compactButton = UIButton(type: .system)
    private let footnoteLabel = UILabel()
    private var barWidthConstraint: NSLayoutConstraint?
    private var isCompacting = false

    init(breakdown: ContextBuilder.Breakdown) {
        self.breakdown = breakdown
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "上下文占用"
        if #available(iOS 13.0, *) {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .close,
                target: self,
                action: #selector(closeTapped)
            )
        } else {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                title: "关闭",
                style: .plain,
                target: self,
                action: #selector(closeTapped)
            )
        }
        setup()
        applyTheme()
        reloadContent()
    }

    func applyTheme() {
        let c = DSTheme.c
        view.backgroundColor = c.background
        percentLabel.textColor = c.textPrimary
        tokenLabel.textColor = c.textSecondary
        barTrack.backgroundColor = c.border.withAlphaComponent(0.35)
        footnoteLabel.textColor = c.textSecondary
        compactButton.setTitleColor(c.accent, for: .normal)
        compactButton.backgroundColor = c.accent.withAlphaComponent(0.12)
        navigationController?.navigationBar.barTintColor = c.background
        navigationController?.navigationBar.tintColor = c.textPrimary
        navigationController?.navigationBar.titleTextAttributes = [.foregroundColor: c.textPrimary]
        if #available(iOS 13.0, *) {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = c.background
            appearance.titleTextAttributes = [.foregroundColor: c.textPrimary]
            navigationController?.navigationBar.standardAppearance = appearance
            if #available(iOS 15.0, *) {
                navigationController?.navigationBar.scrollEdgeAppearance = appearance
            }
        }
        reloadLegend()
    }

    func setCompacting(_ on: Bool) {
        isCompacting = on
        compactButton.isEnabled = !on
        compactButton.setTitle(on ? "正在压缩…" : compactTitle, for: .normal)
    }

    private var compactTitle: String {
        breakdown.usage.shouldAutoCompact ? "压缩上下文" : "整理上下文"
    }

    private func setup() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 16
        scrollView.addSubview(stack)

        let header = UIStackView(arrangedSubviews: [percentLabel, UIView(), tokenLabel])
        header.axis = .horizontal
        header.alignment = .firstBaseline
        percentLabel.font = UIFont.systemFont(ofSize: 28, weight: .bold)
        tokenLabel.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        tokenLabel.textAlignment = .right
        stack.addArrangedSubview(header)

        barTrack.translatesAutoresizingMaskIntoConstraints = false
        barTrack.layer.cornerRadius = 4
        barTrack.clipsToBounds = true
        stack.addArrangedSubview(barTrack)
        barWidthConstraint = barTrack.heightAnchor.constraint(equalToConstant: 8)
        barWidthConstraint?.isActive = true

        legendStack.axis = .vertical
        legendStack.spacing = 10
        stack.addArrangedSubview(legendStack)

        compactButton.translatesAutoresizingMaskIntoConstraints = false
        compactButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        compactButton.layer.cornerRadius = 10
        compactButton.connectsSetContentInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        compactButton.addTarget(self, action: #selector(compactTapped), for: .touchUpInside)
        stack.addArrangedSubview(compactButton)

        footnoteLabel.font = UIFont.systemFont(ofSize: 12)
        footnoteLabel.numberOfLines = 0
        stack.addArrangedSubview(footnoteLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20),

            compactButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    private func reloadContent() {
        percentLabel.text = "\(breakdown.usage.percent)% 已满"
        let used = ContextBuilder.formatTokenEstimate(breakdown.usage.usedChars)
        let budget = ContextBuilder.formatTokenEstimate(breakdown.usage.budgetChars)
        tokenLabel.text = "\(used) / \(budget) Tokens"
        compactButton.setTitle(compactTitle, for: .normal)
        compactButton.isHidden = breakdown.usage.percent < 35 && !breakdown.usage.shouldAutoCompact

        var notes: [String] = ["字符数按约 2 字符 / Token 估算，仅供参考。"]
        notes.append("模型：\(breakdown.modelName)")
        if breakdown.summaryActive {
            notes.append("较早对话已压缩为摘要。")
        }
        if breakdown.droppedTurnCount > 0 {
            notes.append("预算内已折叠 \(breakdown.droppedTurnCount) 条历史轮次。")
        }
        footnoteLabel.text = notes.joined(separator: "\n")
        reloadLegend()
        rebuildBar()
    }

    private func reloadLegend() {
        legendStack.arrangedSubviews.forEach {
            legendStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let c = DSTheme.c
        for item in breakdown.items {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 10
            row.alignment = .center

            let swatch = UIView()
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.backgroundColor = item.color
            swatch.layer.cornerRadius = 3
            NSLayoutConstraint.activate([
                swatch.widthAnchor.constraint(equalToConstant: 10),
                swatch.heightAnchor.constraint(equalToConstant: 10)
            ])

            let title = UILabel()
            title.text = item.title
            title.font = UIFont.systemFont(ofSize: 14, weight: .medium)
            title.textColor = c.textPrimary

            let value = UILabel()
            value.text = ContextBuilder.formatTokenEstimate(item.chars)
            value.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            value.textColor = c.textSecondary
            value.textAlignment = .right
            value.setContentHuggingPriority(.required, for: .horizontal)

            row.addArrangedSubview(swatch)
            row.addArrangedSubview(title)
            row.addArrangedSubview(value)
            legendStack.addArrangedSubview(row)
        }
    }

    private func rebuildBar() {
        barTrack.subviews.forEach { $0.removeFromSuperview() }
        let total = max(1, breakdown.items.reduce(0) { $0 + $1.chars })
        var x: CGFloat = 0
        let height: CGFloat = 8
        for item in breakdown.items where item.chars > 0 {
            let width = max(2, CGFloat(item.chars) / CGFloat(total) * 320)
            let segment = UIView(frame: CGRect(x: x, y: 0, width: width, height: height))
            segment.backgroundColor = item.color
            segment.autoresizingMask = [.flexibleRightMargin, .flexibleHeight]
            barTrack.addSubview(segment)
            x += width
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let total = max(1, breakdown.items.reduce(0) { $0 + $1.chars })
        var x: CGFloat = 0
        let height = barTrack.bounds.height
        let width = barTrack.bounds.width
        var index = 0
        for item in breakdown.items where item.chars > 0 {
            guard index < barTrack.subviews.count else { break }
            let segment = barTrack.subviews[index]
            let segmentWidth = max(2, CGFloat(item.chars) / CGFloat(total) * width)
            segment.frame = CGRect(x: x, y: 0, width: segmentWidth, height: height)
            x += segmentWidth
            index += 1
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func compactTapped() {
        guard !isCompacting else { return }
        onCompact?()
    }
}
