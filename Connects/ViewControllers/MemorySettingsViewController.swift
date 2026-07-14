import UIKit

final class MemorySettingsViewController: UIViewController {
    private let picker = UISegmentedControl(items: MemoryPromptKind.allCases.map(\.title))
    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Memory 高级设置"
        view.backgroundColor = DSTheme.c.sidebarBackground
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.selectedSegmentIndex = 0
        picker.addTarget(self, action: #selector(loadPrompt), for: .valueChanged)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = DSTheme.monoFont(size: 14)
        textView.backgroundColor = DSTheme.c.surface
        textView.textColor = DSTheme.c.textPrimary
        textView.layer.cornerRadius = 10
        view.addSubview(picker); view.addSubview(textView)
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            picker.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            picker.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 14),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "保存", style: .done, target: self, action: #selector(save)),
            UIBarButtonItem(title: "恢复默认", style: .plain, target: self, action: #selector(restore))
        ]
        loadPrompt()
    }
    private var kind: MemoryPromptKind { MemoryPromptKind.allCases[picker.selectedSegmentIndex] }
    @objc private func loadPrompt() { textView.text = MemoryStore.shared.prompt(for: kind) }
    @objc private func save() { MemoryStore.shared.setPrompt(textView.text, for: kind) }
    @objc private func restore() { MemoryStore.shared.restoreDefaultPrompt(for: kind); loadPrompt() }
}
