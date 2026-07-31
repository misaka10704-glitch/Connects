import UIKit

/// Full code fence viewer with keyword highlighting (opened from chat preview cards).
final class ChatCodeFencePopupViewController: UIViewController {
    private let code: String
    private let language: StudyTextLanguage
    private let titleText: String

    private let textView = UITextView()
    private let closeButton = UIButton(type: .system)

    init(code: String, language: StudyTextLanguage, title: String) {
        self.code = code
        self.language = language
        self.titleText = title
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.selectedDetentIdentifier = .large
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DSTheme.c.background

        navigationItem.title = titleText
        closeButton.setTitle("完成", for: .normal)
        closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: closeButton)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = DSTheme.c.surface
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 20, right: 12)
        textView.font = CodeSyntaxHighlighter.font(size: CodeSyntaxHighlighter.defaultPointSize)
        textView.attributedText = CodeSyntaxHighlighter.highlight(
            code,
            language: language,
            fontSize: CodeSyntaxHighlighter.defaultPointSize
        )
        textView.textColor = DSTheme.c.textPrimary
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    static func present(from presenter: UIViewController,
                        code: String,
                        language: StudyTextLanguage,
                        title: String) {
        let popup = ChatCodeFencePopupViewController(code: code, language: language, title: title)
        let nav = UINavigationController(rootViewController: popup)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.selectedDetentIdentifier = .large
        }
        presenter.present(nav, animated: true)
    }
}
