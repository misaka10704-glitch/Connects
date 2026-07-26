import UIKit

/// Read-only sheet for assistant thinking / search / transcription text.
final class MessageChromeViewerViewController: UIViewController {
    private let bodyText: String
    private let textView = UITextView()

    init(title: String, body: String) {
        bodyText = body
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let c = DSTheme.c
        view.backgroundColor = c.background

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.backgroundColor = c.background
        textView.textColor = c.textPrimary
        textView.font = UIFont.systemFont(ofSize: SettingsManager.shared.chatThinkingFontSize)
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        textView.text = bodyText
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    static func present(from host: UIViewController,
                        title: String,
                        body: String,
                        sourceView: UIView?) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let vc = MessageChromeViewerViewController(title: title, body: body)
        let nav = UINavigationController(rootViewController: vc)
        if #available(iOS 13.0, *) {
            nav.isModalInPresentation = false
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
            nav.modalPresentationStyle = .formSheet
            if let pop = nav.popoverPresentationController, let sourceView = sourceView {
                pop.sourceView = sourceView
                pop.sourceRect = sourceView.bounds
                pop.permittedArrowDirections = [.up, .down]
            }
        } else if #available(iOS 13.0, *) {
            nav.modalPresentationStyle = .pageSheet
        } else {
            nav.modalPresentationStyle = .formSheet
        }
        host.present(nav, animated: true)
    }
}
