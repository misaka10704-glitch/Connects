import UIKit
import PDFKit
import WebKit

/// Stashes a selection from Ask so it survives focus loss; injected as hidden API context.
final class StudyAskSelectionStore {
    static let shared = StudyAskSelectionStore()

    static let askAnnotationUserName = "connects.ask"
    static let noteAnnotationUserName = "connects.note"

    private var pending: [String: String] = [:]

    private init() {}

    func setPending(_ text: String, conversationID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pending[conversationID] = String(trimmed.prefix(4_000))
    }

    func pendingText(for conversationID: String) -> String? {
        pending[conversationID]
    }

    func consume(for conversationID: String) -> String? {
        let value = pending[conversationID]
        pending.removeValue(forKey: conversationID)
        return value
    }

    func clear(conversationID: String) {
        pending.removeValue(forKey: conversationID)
    }
}

enum StudyAskMenu {
    static let askSelector = #selector(StudyAskHandling.studyAskSelectedText)

    private static var installed = false

    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        UIMenuController.shared.menuItems = [
            UIMenuItem(title: "Ask", action: askSelector)
        ]
    }
}

@objc protocol StudyAskHandling {
    @objc func studyAskSelectedText()
}

/// UITextView with Ask in the edit menu (code / Markdown editor).
final class StudyAskTextView: UITextView, StudyAskHandling {
    var onAskSelection: ((String) -> Void)?
    /// Optional hardware key commands while this view is first responder (code editor).
    var editorKeyCommandsProvider: (() -> [UIKeyCommand]?)?

    override var keyCommands: [UIKeyCommand]? {
        editorKeyCommandsProvider?() ?? super.keyCommands
    }

    /// Code Diff: full-line red/green via `DiffFullLineBackgroundLayoutManager`.
    convenience init(frame: CGRect = .zero, fullLineBackgrounds: Bool) {
        if fullLineBackgrounds {
            let storage = NSTextStorage()
            let layout = DiffFullLineBackgroundLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
            container.widthTracksTextView = true
            container.heightTracksTextView = false
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            self.init(frame: frame, textContainer: container)
        } else {
            self.init(frame: frame, textContainer: nil)
        }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        StudyAskMenu.installIfNeeded()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        StudyAskMenu.installIfNeeded()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == StudyAskMenu.askSelector {
            return selectedTextForAsk() != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func studyAskSelectedText() {
        guard let text = selectedTextForAsk() else { return }
        onAskSelection?(text)
    }

    private func selectedTextForAsk() -> String? {
        guard let range = selectedTextRange, !range.isEmpty,
              let text = text(in: range)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    /// Prefer Diff Keep/Undo (and other) chrome subviews over text selection hit-testing.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for sub in subviews.reversed() where !sub.isHidden && sub.alpha > 0.01 && sub.isUserInteractionEnabled {
            let local = convert(point, to: sub)
            if let hit = sub.hitTest(local, with: event) {
                return hit
            }
        }
        return super.hitTest(point, with: event)
    }
}

/// PDF reader view: scroll + freehand ink pen + tap notes. No Ask / no free text selection.
final class StudyPDFView: PDFView {
    let highlighter = PDFHighlighterTool()
    let noteTap = PDFHighlightNoteTap()
    private var selectionObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        if let selectionObserver = selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
        }
    }

    private func commonInit() {
        highlighter.attach(to: self)
        noteTap.attach(to: self)
        suppressNativeTextInteraction()
        selectionObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.PDFViewSelectionChanged,
            object: self,
            queue: .main
        ) { [weak self] _ in
            self?.rejectStraySelection()
        }
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        highlighter.ensureHostOverlaysInstalled()
        highlighter.reloadCommittedInk()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        highlighter.noteHostDidLayout()
    }

    override var canBecomeFirstResponder: Bool { false }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // Block Copy / Look Up / Ask / share menus from text selection.
        false
    }

    /// Kill PDFKit's built-in long-press / selection recognizers.
    func suppressNativeTextInteraction() {
        for gr in gestureRecognizers ?? [] {
            if gr is UILongPressGestureRecognizer {
                gr.isEnabled = false
            }
        }
        for sub in subviews {
            disableSelectionRecognizers(in: sub)
        }
    }

    private func disableSelectionRecognizers(in view: UIView) {
        for gr in view.gestureRecognizers ?? [] {
            if gr is UILongPressGestureRecognizer {
                gr.isEnabled = false
            }
        }
        for child in view.subviews {
            disableSelectionRecognizers(in: child)
        }
    }

    private func rejectStraySelection() {
        guard !highlighter.isActivelyHighlighting else { return }
        if currentSelection != nil {
            clearSelection()
        }
    }
}

/// WKWebView with Ask; reads `window.getSelection()`.
final class StudyAskWebView: WKWebView, StudyAskHandling {
    var onAskSelection: ((String) -> Void)?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        StudyAskMenu.installIfNeeded()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        StudyAskMenu.installIfNeeded()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == StudyAskMenu.askSelector { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func studyAskSelectedText() {
        evaluateJavaScript("window.getSelection ? window.getSelection().toString() : ''") { [weak self] result, _ in
            let text = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return }
            DispatchQueue.main.async {
                self?.onAskSelection?(text)
            }
        }
    }
}
