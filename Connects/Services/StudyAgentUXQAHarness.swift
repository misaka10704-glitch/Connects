#if DEBUG
import UIKit

/// Visual QA for Study Agent UX (Ask icon, Files entry, workspace menu).
/// Launch: `-StudyAgentUXQA`
/// Frames: Documents/ConnectsVisualQA/agent_ux/*.png
enum StudyAgentUXQAHarness {
    private static let logTag = "[StudyAgentUXQA]"
    private static var didRun = false
    private static let scenario = "agent_ux"

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-StudyAgentUXQA") else { return }
        guard !didRun else { return }
        didRun = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            run()
        }
    }

    private static func emit(_ message: String) {
        let line = "\(logTag) \(message)"
        NSLog("%@", line)
        fputs(line + "\n", stderr)
        fflush(stderr)
    }

    private static func visualDir() -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = docs
            .appendingPathComponent("ConnectsVisualQA", isDirectory: true)
            .appendingPathComponent(scenario, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private static func capture(_ view: UIView, frame: String) -> URL? {
        guard view.bounds.width > 2, view.bounds.height > 2 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(UIScreen.main.scale, 2)
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds, format: format)
        let image = renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData(), let dir = visualDir() else { return nil }
        let url = dir.appendingPathComponent("\(frame).png")
        try? data.write(to: url, options: .atomic)
        emit("shot \(scenario)/\(frame).png \(Int(image.size.width))x\(Int(image.size.height))")
        return url
    }

    private static func findChatVC(in root: UIViewController?) -> ChatViewController? {
        guard let root else { return nil }
        if let chat = root as? ChatViewController { return chat }
        for child in root.children {
            if let found = findChatVC(in: child) { return found }
        }
        if let presented = root.presentedViewController {
            return findChatVC(in: presented)
        }
        return nil
    }

    private static func run() {
        emit("begin agent UX visual suite")
        var failures: [String] = []

        // 1) Isolated input bar: Ask icon then Agent chip.
        let host = UIViewController()
        host.view.backgroundColor = DSTheme.c.background
        let bar = InputBarView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: host.view.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: host.view.trailingAnchor, constant: -16),
            bar.centerYAnchor.constraint(equalTo: host.view.centerYAnchor),
            bar.heightAnchor.constraint(greaterThanOrEqualToConstant: 88)
        ])
        bar.codeAIEditVisible = true
        bar.setAskSelectionSlotVisible(true)
        bar.setAskSelectionArmed(true)
        bar.studyAgentModeVisible = true
        bar.setStudyAgentMode(.agent, notify: false)
        bar.setModelChip(title: "Kimi")
        bar.applyTheme()

        let nav = UINavigationController(rootViewController: host)
        nav.modalPresentationStyle = .fullScreen
        guard let root = UIApplication.connectsKeyWindow?.rootViewController else {
            emit("FAIL no root")
            exit(1)
        }
        var presenter = root
        while let p = presenter.presentedViewController { presenter = p }
        presenter.present(nav, animated: false) {
            host.view.layoutIfNeeded()
            bar.layoutIfNeeded()
            self.capture(host.view, frame: "01_inputbar_ask_then_agent")
            // Assert geometry: ask left of agent.
            if let ask = self.subview(named: "Ask 选区", in: bar),
               let agent = self.subview(namedContains: "Agent 模式", in: bar) {
                if ask.frame.maxX > agent.frame.minX + 1 {
                    failures.append("Ask icon not left of Agent chip (ask.maxX=\(Int(ask.frame.maxX)) agent.minX=\(Int(agent.frame.minX)))")
                } else {
                    self.emit("PASS Ask left of Agent chip")
                }
            } else {
                failures.append("missing Ask or Agent accessibility views in InputBar")
            }

            // Mode titles must stay readable (regression: Plan/Ask near-invisible).
            let modeChecks: [(StudyAgentMode, String, String)] = [
                (.agent, "Agent 模式 · Agent", "01b_mode_agent"),
                (.plan, "Agent 模式 · Plan", "02_inputbar_plan"),
                (.ask, "Agent 模式 · Ask", "03_inputbar_ask_mode")
            ]
            for (mode, expected, frame) in modeChecks {
                bar.setStudyAgentMode(mode, notify: false)
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                bar.layoutIfNeeded()
                guard let chip = self.subview(named: expected, in: bar) as? UIButton else {
                    failures.append("missing mode chip a11y \(expected)")
                    continue
                }
                let title = chip.attributedTitle(for: .normal)?.string
                    ?? chip.title(for: .normal)
                    ?? ""
                let want: String
                switch mode {
                case .agent: want = "Agent"
                case .plan: want = "Plan"
                case .ask: want = "Ask"
                }
                if title != want {
                    failures.append("mode chip title \(title) expected \(want)")
                }
                if chip.alpha < 0.9 {
                    failures.append("mode chip \(want) alpha \(chip.alpha) too low")
                }
                self.capture(host.view, frame: frame)
            }
            self.emit("PASS mode chip titles Agent/Plan/Ask")

            nav.dismiss(animated: false) {
                self.runPickerPhase(failures: failures)
            }
        }
    }

    private static func subview(named label: String, in root: UIView) -> UIView? {
        if root.accessibilityLabel == label { return root }
        for child in root.subviews {
            if let found = subview(named: label, in: child) { return found }
        }
        return nil
    }

    private static func subview(namedContains needle: String, in root: UIView) -> UIView? {
        if let lab = root.accessibilityLabel, lab.contains(needle) { return root }
        for child in root.subviews {
            if let found = subview(namedContains: needle, in: child) { return found }
        }
        return nil
    }

    private static func runPickerPhase(failures: [String]) {
        var failures = failures
        let picker = StudyDocumentPickerViewController()
        let nav = UINavigationController(rootViewController: picker)
        nav.modalPresentationStyle = .formSheet
        guard let root = UIApplication.connectsKeyWindow?.rootViewController else {
            emit("FAIL no root for picker")
            finish(failures: failures)
            return
        }
        var presenter = root
        while let p = presenter.presentedViewController { presenter = p }
        presenter.present(nav, animated: false) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                picker.view.layoutIfNeeded()
                self.capture(picker.view, frame: "04_picker_select_attach")
                let texts = self.tableCellTitles(in: picker.view)
                self.emit("picker rows: \(texts.joined(separator: " | "))")
                if texts.contains(where: { $0.contains("打开工作区") }) {
                    failures.append("picker still shows 打开工作区 rows")
                }
                if texts.contains(where: { $0.contains("新建文件夹工作区") }) {
                    failures.append("picker still shows 新建文件夹工作区")
                }
                if !texts.contains(where: { $0.contains("打开 Files") }) {
                    failures.append("picker missing 打开 Files…")
                } else {
                    self.emit("PASS picker has 打开 Files…")
                }
                if picker.title != "选择依附" {
                    failures.append("picker title is \(picker.title ?? "nil"), expected 选择依附")
                }

                nav.dismiss(animated: false) {
                    self.runMenuPhase(failures: failures)
                }
            }
        }
    }

    private static func tableCellTitles(in root: UIView) -> [String] {
        var out: [String] = []
        func walk(_ v: UIView) {
            if let cell = v as? UITableViewCell, let t = cell.textLabel?.text {
                out.append(t)
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out
    }

    private static func runMenuPhase(failures: [String]) {
        var failures = failures
        let host = UIViewController()
        host.view.backgroundColor = DSTheme.c.background
        let anchor = UIView(frame: CGRect(x: 200, y: 120, width: 40, height: 40))
        host.view.addSubview(anchor)

        let nav = UINavigationController(rootViewController: host)
        nav.modalPresentationStyle = .fullScreen
        guard let root = UIApplication.connectsKeyWindow?.rootViewController else {
            finish(failures: failures)
            return
        }
        var presenter = root
        while let p = presenter.presentedViewController { presenter = p }
        presenter.present(nav, animated: false) {
            ConnectsMenu.present(
                from: host,
                title: "DemoWorkspace",
                items: [
                    ConnectsMenuItem(title: "main.swift", icon: .book) {},
                    ConnectsMenuItem(title: "notes.md", icon: .book) {}
                ],
                sourceView: anchor,
                titleTap: {},
                headerTrailingActions: [
                    ConnectsMenuHeaderAction(icon: .plus, accessibilityLabel: "新建文件") {},
                    ConnectsMenuHeaderAction(icon: .importFile, accessibilityLabel: "添加文件到工作区") {}
                ]
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                if let menu = self.topPresented() {
                    self.capture(menu.view, frame: "05_workspace_menu_header")
                    let hasPlus = self.subview(named: "新建文件", in: menu.view) != nil
                    let hasImport = self.subview(named: "添加文件到工作区", in: menu.view) != nil
                    if hasPlus && hasImport {
                        self.emit("PASS menu header + / import")
                    } else {
                        failures.append("menu header missing + or import (plus=\(hasPlus) import=\(hasImport))")
                    }
                    // Reject legacy text rows.
                    let labels = self.collectLabels(in: menu.view)
                    if labels.contains(where: { $0.contains("新建文件…") || $0.contains("添加文件到工作区…") }) {
                        failures.append("menu still has text rows for new/import")
                    }
                    if labels.contains(where: { $0.hasPrefix("工作区：") }) {
                        failures.append("menu still has 工作区： list row")
                    }
                } else {
                    failures.append("ConnectsMenu not presented")
                }
                host.dismiss(animated: false) {
                    self.finish(failures: failures)
                }
            }
        }
    }

    private static func collectLabels(in root: UIView) -> [String] {
        var out: [String] = []
        func walk(_ v: UIView) {
            if let lab = v as? UILabel, let t = lab.text, !t.isEmpty { out.append(t) }
            if let btn = v as? UIButton, let t = btn.title(for: .normal), !t.isEmpty { out.append(t) }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out
    }

    private static func topPresented() -> UIViewController? {
        var top = UIApplication.connectsKeyWindow?.rootViewController
        while let p = top?.presentedViewController { top = p }
        return top
    }

    private static func finish(failures: [String]) {
        if failures.isEmpty {
            emit("PASS agent UX visual suite")
            emit("PULL /tmp/connects_visual_qa via Scripts/pull-visual-qa.sh")
            exit(0)
        } else {
            for f in failures { emit("FAIL \(f)") }
            emit("PULL /tmp/connects_visual_qa via Scripts/pull-visual-qa.sh")
            exit(1)
        }
    }
}
#endif
