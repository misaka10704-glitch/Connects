import UIKit

protocol ContextUsageViewDelegate: AnyObject {
    func contextUsageViewDidTapCompact(_ view: ContextUsageView)
}

/// ChatGPT-like context fill meter above the composer.
final class ContextUsageView: UIView, ThemeRefreshable {
    weak var delegate: ContextUsageViewDelegate?

    private let track = UIView()
    private let fill = UIView()
    private let label = UILabel()
    private let compactButton = UIButton(type: .system)
    private var fillWidth: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var lastPercent = 0
    private var isCompacting = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
        applyTheme()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
        applyTheme()
    }

    func applyTheme() {
        let c = DSTheme.c
        backgroundColor = .clear
        track.backgroundColor = c.border.withAlphaComponent(0.45)
        label.textColor = c.textSecondary
        compactButton.setTitleColor(c.accent, for: .normal)
        updateFillColor(for: lastPercent)
    }

    func setCompacting(_ on: Bool) {
        isCompacting = on
        compactButton.isEnabled = !on
        if on {
            label.text = "正在压缩上下文…"
            compactButton.setTitle("…", for: .normal)
            heightConstraint?.constant = 28
            isHidden = false
        }
    }

    /// - Parameters:
    ///   - forceVisible: keep the meter on whenever the chat has content (avoids flicker).
    func update(usage: ContextBuilder.Usage, forceVisible: Bool, animated: Bool = true) {
        lastPercent = usage.percent
        let show = forceVisible || usage.shouldAutoCompact || isCompacting
        isHidden = !show
        heightConstraint?.constant = show ? 28 : 0
        guard show else { return }

        if isCompacting {
            label.text = "正在压缩上下文…"
            compactButton.setTitle("…", for: .normal)
            compactButton.isHidden = false
        } else {
            label.text = "上下文 \(usage.percent)%"
            compactButton.setTitle(usage.shouldAutoCompact ? "压缩" : "整理", for: .normal)
            compactButton.isHidden = usage.percent < 35
        }
        updateFillColor(for: usage.percent)

        let ratio = CGFloat(max(0.02, min(1, usage.ratio)))
        let apply = {
            self.fillWidth?.isActive = false
            // Avoid zero-width track before layout: fall back to constant when needed.
            if self.track.bounds.width > 1 {
                self.fillWidth = self.fill.widthAnchor.constraint(equalToConstant: self.track.bounds.width * ratio)
            } else {
                self.fillWidth = self.fill.widthAnchor.constraint(equalTo: self.track.widthAnchor, multiplier: ratio)
            }
            self.fillWidth?.isActive = true
            self.layoutIfNeeded()
        }
        if animated {
            UIView.animate(withDuration: 0.22, animations: apply)
        } else {
            apply()
        }
    }

    private func updateFillColor(for percent: Int) {
        let c = DSTheme.c
        if percent >= 75 {
            fill.backgroundColor = UIColor(red: 0.92, green: 0.35, blue: 0.32, alpha: 1)
        } else if percent >= 50 {
            fill.backgroundColor = UIColor(red: 0.95, green: 0.68, blue: 0.22, alpha: 1)
        } else {
            fill.backgroundColor = c.accent
        }
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true

        track.translatesAutoresizingMaskIntoConstraints = false
        track.layer.cornerRadius = 2
        track.clipsToBounds = true
        addSubview(track)

        fill.translatesAutoresizingMaskIntoConstraints = false
        fill.layer.cornerRadius = 2
        track.addSubview(fill)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        addSubview(label)

        compactButton.translatesAutoresizingMaskIntoConstraints = false
        compactButton.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        compactButton.addTarget(self, action: #selector(compactTapped), for: .touchUpInside)
        addSubview(compactButton)

        fillWidth = fill.widthAnchor.constraint(equalToConstant: 0)
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            heightConstraint!,

            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),

            compactButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            compactButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            compactButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),

            track.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            track.trailingAnchor.constraint(equalTo: compactButton.leadingAnchor, constant: -10),
            track.centerYAnchor.constraint(equalTo: centerYAnchor),
            track.heightAnchor.constraint(equalToConstant: 4),

            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fillWidth!
        ])

        isHidden = true
    }

    @objc private func compactTapped() {
        guard !isCompacting else { return }
        delegate?.contextUsageViewDidTapCompact(self)
    }
}
