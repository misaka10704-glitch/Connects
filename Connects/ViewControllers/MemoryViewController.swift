import UIKit

final class MemoryViewController: UIViewController, UITextViewDelegate {
    private let pendingButton = UIButton(type: .system)
    private let scrollView = UIScrollView()
    private let renderedView = NativeMessageRenderView()
    private let sourceView = UITextView()
    private var renderHeight: NSLayoutConstraint!
    private var isEditingMemory = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Memory"
        view.backgroundColor = DSTheme.c.background
        pendingButton.translatesAutoresizingMaskIntoConstraints = false
        pendingButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        pendingButton.addTarget(self, action: #selector(showPending), for: .touchUpInside)
        view.addSubview(pendingButton)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        renderedView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(renderedView)
        view.addSubview(scrollView)
        sourceView.translatesAutoresizingMaskIntoConstraints = false
        sourceView.font = DSTheme.monoFont(size: 14)
        sourceView.textColor = DSTheme.c.textPrimary
        sourceView.backgroundColor = DSTheme.c.surface
        sourceView.delegate = self
        sourceView.isHidden = true
        view.addSubview(sourceView)
        renderHeight = renderedView.heightAnchor.constraint(equalToConstant: 1)
        NSLayoutConstraint.activate([
            pendingButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            pendingButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            pendingButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            pendingButton.heightAnchor.constraint(equalToConstant: 34),
            scrollView.topAnchor.constraint(equalTo: pendingButton.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            renderedView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            renderedView.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            renderedView.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
            renderedView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
            renderHeight,
            sourceView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            sourceView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            sourceView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            sourceView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        ])
        navigationItem.leftBarButtonItem = ActionIconFactory.barItem(kind: .chevronLeft, target: self, action: #selector(goBack), accessibility: "返回")
        navigationItem.rightBarButtonItems = [
            ActionIconFactory.barItem(kind: .more, target: self, action: #selector(showMemoryMenu), accessibility: "Memory 选项"),
            ActionIconFactory.barItem(kind: .edit, target: self, action: #selector(toggleEdit), accessibility: "编辑 Memory")
        ]
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .memoryStoreDidUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        renderedView.onLinkTap = { [weak self] url in self?.openConversation(url) ?? false }
        refresh()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !isEditingMemory else { return }
        let height = renderedView.configure(content: MemoryStore.shared.assembledMarkdown(),
                                            width: max(view.bounds.width - 32, 40),
                                            fontSize: 15,
                                            appearance: SettingsManager.shared.appearanceMode.rawValue,
                                            colors: DSTheme.c)
        renderHeight.constant = height
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func keyboardChanged(_ note: Notification) {
        guard isEditingMemory,
              let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let overlap = max(0, view.bounds.maxY - view.convert(frame, from: nil).minY)
        sourceView.contentInset.bottom = overlap + 18
        sourceView.scrollIndicatorInsets.bottom = overlap
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        DispatchQueue.main.async { [weak self] in
            self?.sourceView.scrollRangeToVisible(self?.sourceView.selectedRange ?? NSRange(location: 0, length: 0))
        }
    }

    private func openConversation(_ url: URL) -> Bool {
        guard url.scheme == "connects",
              url.host == "conversation",
              let id = url.pathComponents.dropFirst().first,
              ConversationStore.shared.conversations.contains(where: { $0.id == id }) else { return false }
        ConversationStore.shared.selectConversation(id: id)
        navigationController?.popViewController(animated: true)
        return true
    }

    @objc private func refresh() {
        let pending = MemoryStore.shared.pendingChanges()
        pendingButton.isHidden = pending.isEmpty
        pendingButton.setTitle(pending.isEmpty ? "" : "\(pending.count) 项背景改写待确认", for: .normal)
        sourceView.text = MemoryStore.shared.assembledMarkdown()
        view.setNeedsLayout()
    }

    @objc private func toggleEdit() {
        isEditingMemory.toggle()
        scrollView.isHidden = isEditingMemory
        sourceView.isHidden = !isEditingMemory
        navigationItem.rightBarButtonItems?.last?.image = ActionIconFactory.image(isEditingMemory ? .send : .edit, pointSize: 16)
        if !isEditingMemory {
            let draft = sourceView.text ?? ""
            let marker = "## 整体背景"
            if let range = draft.range(of: marker) {
                MemoryStore.shared.proposeBackgroundUpdate(String(draft[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            refresh()
            if let pending = MemoryStore.shared.pendingChanges().first {
                navigationController?.pushViewController(DiffPreviewViewController(before: pending.before, after: pending.after,
                                                                                     keep: { MemoryStore.shared.commit(pending) },
                                                                                     undo: { MemoryStore.shared.discard(pending) }), animated: true)
            }
        }
    }

    @objc private func showPending() {
        guard let pending = MemoryStore.shared.pendingChanges().first else { return }
        navigationController?.pushViewController(DiffPreviewViewController(before: pending.before, after: pending.after,
                                                                             keep: { MemoryStore.shared.commit(pending) },
                                                                             undo: { MemoryStore.shared.discard(pending) }), animated: true)
    }
    @objc private func openSettings() { navigationController?.pushViewController(MemorySettingsViewController(), animated: true) }
    @objc private func goBack() { navigationController?.popViewController(animated: true) }

    @objc private func showMemoryMenu() {
        ConnectsMenu.present(from: self, title: "Memory", items: [
            ConnectsMenuItem(title: "Memory 设置", icon: .settings) { [weak self] in self?.openSettings() },
            ConnectsMenuItem(title: "背景版本", icon: .archive) { [weak self] in self?.showRevisions() },
            ConnectsMenuItem(title: "清空已确认 Memory", icon: .trash, isDestructive: true) {
                MemoryStore.shared.clearAll()
            }
        ], barButtonItem: navigationItem.rightBarButtonItems?.first, preferVertical: true)
    }

    @objc private func showRevisions() {
        let revisions = MemoryStore.shared.revisions()
        let alert = UIAlertController(title: "背景版本", message: nil, preferredStyle: .actionSheet)
        for revision in revisions.prefix(8) {
            let title = "\(revision.id) · \(DateFormatter.localizedString(from: revision.createdAt, dateStyle: .short, timeStyle: .short))"
            alert.addAction(UIAlertAction(title: title, style: .default) { _ in
                let confirm = UIAlertController(title: "回退到此版本？", message: "会创建新的回退记录。", preferredStyle: .alert)
                confirm.addAction(UIAlertAction(title: "取消", style: .cancel))
                confirm.addAction(UIAlertAction(title: "回退", style: .destructive) { _ in MemoryStore.shared.revert(to: revision) })
                self.present(confirm, animated: true)
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let pop = alert.popoverPresentationController { pop.barButtonItem = navigationItem.rightBarButtonItems?.first }
        present(alert, animated: true)
    }
}
