import UIKit

/// Shows the user question for the reply currently in view; tap to pick any turn.
final class TurnContextBarView: UIView, ThemeRefreshable {
    private let borderView = UIView()
    private let prefixLabel = UILabel()
    private let questionLabel = UILabel()
    private let chevronLabel = UILabel()
    private var heightConstraint: NSLayoutConstraint?

    var onTap: (() -> Void)?

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
        borderView.backgroundColor = c.surfaceHover
        borderView.layer.borderColor = c.border.cgColor
        prefixLabel.textColor = c.textSecondary
        questionLabel.textColor = c.textPrimary
        chevronLabel.textColor = c.accent
    }

    func update(question: String?, visible: Bool) {
        let show = visible && !(question?.isEmpty ?? true)
        isHidden = !show
        isUserInteractionEnabled = show
        heightConstraint?.constant = show ? 36 : 0
        guard show, let question = question else {
            questionLabel.text = nil
            return
        }
        questionLabel.text = question
        accessibilityLabel = "当前问题：\(question)。点按选择并跳转到其他问题。"
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true

        borderView.translatesAutoresizingMaskIntoConstraints = false
        borderView.layer.cornerRadius = 8
        borderView.layer.borderWidth = 1 / UIScreen.main.scale
        borderView.clipsToBounds = true
        addSubview(borderView)

        prefixLabel.translatesAutoresizingMaskIntoConstraints = false
        prefixLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        prefixLabel.text = "问题"
        prefixLabel.setContentHuggingPriority(.required, for: .horizontal)
        prefixLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        borderView.addSubview(prefixLabel)

        questionLabel.translatesAutoresizingMaskIntoConstraints = false
        questionLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        questionLabel.lineBreakMode = .byTruncatingTail
        questionLabel.numberOfLines = 1
        borderView.addSubview(questionLabel)

        chevronLabel.translatesAutoresizingMaskIntoConstraints = false
        chevronLabel.font = UIFont.systemFont(ofSize: 11, weight: .bold)
        chevronLabel.text = "▼"
        chevronLabel.textAlignment = .center
        chevronLabel.setContentHuggingPriority(.required, for: .horizontal)
        chevronLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        borderView.addSubview(chevronLabel)

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        borderView.addGestureRecognizer(tap)
        borderView.isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        isAccessibilityElement = true
        accessibilityTraits = .button

        NSLayoutConstraint.activate([
            heightConstraint!,

            borderView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DSTheme.contentHorizontalPadding),
            borderView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DSTheme.contentHorizontalPadding),
            borderView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            borderView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            prefixLabel.leadingAnchor.constraint(equalTo: borderView.leadingAnchor, constant: 10),
            prefixLabel.centerYAnchor.constraint(equalTo: borderView.centerYAnchor),

            chevronLabel.trailingAnchor.constraint(equalTo: borderView.trailingAnchor, constant: -10),
            chevronLabel.centerYAnchor.constraint(equalTo: borderView.centerYAnchor),
            chevronLabel.widthAnchor.constraint(equalToConstant: 16),

            questionLabel.leadingAnchor.constraint(equalTo: prefixLabel.trailingAnchor, constant: 8),
            questionLabel.trailingAnchor.constraint(equalTo: chevronLabel.leadingAnchor, constant: -8),
            questionLabel.centerYAnchor.constraint(equalTo: borderView.centerYAnchor)
        ])

        isHidden = true
        isUserInteractionEnabled = false
    }

    @objc private func handleTap() {
        onTap?()
    }
}
