import UIKit

final class DiffPreviewViewController: UIViewController {
    private let before: String
    private let after: String
    private let keep: () -> Void
    private let undo: () -> Void
    private let stack = UIStackView()

    init(before: String, after: String, keep: @escaping () -> Void, undo: @escaping () -> Void) {
        self.before = before; self.after = after; self.keep = keep; self.undo = undo
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Memory 变更"
        view.backgroundColor = DSTheme.c.background
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll)
        stack.axis = .vertical; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        let actions = UIStackView(); actions.axis = .horizontal; actions.spacing = 12; actions.distribution = .fillEqually; actions.translatesAutoresizingMaskIntoConstraints = false
        let no = button("N  Undo", color: UIColor(red: 0.75, green: 0.18, blue: 0.18, alpha: 1), action: #selector(undoTapped))
        let yes = button("Y  Keep", color: UIColor(red: 0.10, green: 0.55, blue: 0.28, alpha: 1), action: #selector(keepTapped))
        actions.addArrangedSubview(no); actions.addArrangedSubview(yes); view.addSubview(actions)
        NSLayoutConstraint.activate([
            actions.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), actions.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            actions.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10), actions.heightAnchor.constraint(equalToConstant: 44),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12), scroll.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor), stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor), stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor)
        ])
        buildDiff()
        addKeyCommand(UIKeyCommand(input: "y", modifierFlags: [], action: #selector(keepTapped)))
        addKeyCommand(UIKeyCommand(input: "n", modifierFlags: [], action: #selector(undoTapped)))
    }

    private func button(_ title: String, color: UIColor, action: Selector) -> UIButton {
        let b = UIButton(type: .system); b.setTitle(title, for: .normal); b.setTitleColor(.white, for: .normal); b.backgroundColor = color; b.layer.cornerRadius = 10; b.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold); b.addTarget(self, action: action, for: .touchUpInside); return b
    }
    private func buildDiff() {
        let old = before.components(separatedBy: .newlines)
        let new = after.components(separatedBy: .newlines)
        let removed = old.filter { !$0.isEmpty && !new.contains($0) }
        let added = new.filter { !$0.isEmpty && !old.contains($0) }
        if removed.isEmpty && added.isEmpty { stack.addArrangedSubview(line("没有变更", background: DSTheme.c.surface, border: DSTheme.c.border)) }
        removed.forEach { stack.addArrangedSubview(line("− " + $0, background: UIColor(red: 0.85, green: 0.15, blue: 0.15, alpha: 0.13), border: UIColor(red: 0.82, green: 0.2, blue: 0.2, alpha: 0.8))) }
        added.forEach { stack.addArrangedSubview(line("+ " + $0, background: UIColor(red: 0.12, green: 0.65, blue: 0.30, alpha: 0.13), border: UIColor(red: 0.12, green: 0.55, blue: 0.28, alpha: 0.8))) }
    }
    private func line(_ text: String, background: UIColor, border: UIColor) -> UILabel {
        let l = UILabel(); l.numberOfLines = 0; l.text = text; l.font = DSTheme.monoFont(size: 13); l.textColor = DSTheme.c.textPrimary; l.backgroundColor = background; l.layer.borderColor = border.cgColor; l.layer.borderWidth = 1; l.layer.cornerRadius = 8; l.clipsToBounds = true; l.textInsets = UIEdgeInsets(top: 9, left: 10, bottom: 9, right: 10); return l
    }
    @objc private func keepTapped() { keep(); navigationController?.popViewController(animated: true) }
    @objc private func undoTapped() { undo(); navigationController?.popViewController(animated: true) }
}

private extension UILabel {
    var textInsets: UIEdgeInsets {
        get { .zero }
        set { layoutMargins = newValue }
    }
}
