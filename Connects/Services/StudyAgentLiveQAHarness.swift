#if DEBUG
import UIKit

/// Live DeepSeek workspace Agent/Plan multi-file QA with screenshots.
/// Launch: `-StudyAgentLiveQA`
/// Frames: Documents/ConnectsVisualQA/agent_live/*.png
enum StudyAgentLiveQAHarness {
    private static let logTag = "[StudyAgentLiveQA]"
    private static var didRun = false
    private static let scenario = "agent_live"

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-StudyAgentLiveQA") else { return }
        guard !didRun else { return }
        didRun = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
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

    private static func keyWindow() -> UIWindow? {
        if #available(iOS 13.0, *) {
            return UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
                ?? UIApplication.shared.windows.first
        }
        return UIApplication.shared.keyWindow
    }

    private static func findChatVC(in root: UIViewController?) -> ChatViewController? {
        guard let root else { return nil }
        if let chat = root as? ChatViewController { return chat }
        for child in root.children {
            if let chat = findChatVC(in: child) { return chat }
        }
        if let presented = root.presentedViewController {
            return findChatVC(in: presented)
        }
        if let nav = root as? UINavigationController {
            return findChatVC(in: nav.visibleViewController)
        }
        if let split = root as? UISplitViewController {
            for c in split.viewControllers {
                if let chat = findChatVC(in: c) { return chat }
            }
        }
        return nil
    }

    private static func findShell(in root: UIViewController?) -> StudyShellViewController? {
        guard let root else { return nil }
        if let shell = root as? StudyShellViewController { return shell }
        for child in root.children {
            if let shell = findShell(in: child) { return shell }
        }
        if let presented = root.presentedViewController {
            return findShell(in: presented)
        }
        if let nav = root as? UINavigationController {
            return findShell(in: nav.visibleViewController)
        }
        if let split = root as? UISplitViewController {
            for c in split.viewControllers {
                if let shell = findShell(in: c) { return shell }
            }
        }
        return nil
    }

    private static func chromeSnapshotLabels(in view: UIView) -> (hasWorked: Bool, hasThinking: Bool) {
        var worked = false
        var thinking = false
        func walk(_ v: UIView) {
            if let b = v as? UIButton {
                let t = b.title(for: .normal) ?? b.configuration?.title ?? ""
                if t.contains("已工作") || t.contains("工作中") { worked = true }
                if t.contains("深度思考") || t.contains("思考中") { thinking = true }
            }
            if let l = v as? UILabel {
                let t = l.text ?? ""
                if t.contains("已工作") || t.contains("工作中") { worked = true }
                if t.contains("深度思考") || t.contains("思考中") { thinking = true }
            }
            for c in v.subviews { walk(c) }
        }
        walk(view)
        return (worked, thinking)
    }

    /// Detect crushed「工作中」header (< 20pt) and main-thread stalls during agent stream.
    private static func startFreezeWatch(chat: ChatViewController) -> () -> [String] {
        var issues: [String] = []
        var lastPing = Date()
        var ticks = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
            ticks += 1
            let gap = Date().timeIntervalSince(lastPing)
            lastPing = Date()
            // Timer itself runs on main — if we only fire after a long gap, main was blocked.
            if gap > 1.2 {
                issues.append(String(format: "main-thread stall %.1fs (tick %d)", gap, ticks))
                emit("WARN main stall \(String(format: "%.1f", gap))s")
            }
            func walk(_ v: UIView) {
                if let b = v as? UIButton {
                    let t = b.title(for: .normal) ?? b.configuration?.title ?? ""
                    if t.contains("工作中"), b.bounds.height > 0, b.bounds.height < 18 {
                        issues.append("工作中 header crushed h=\(Int(b.bounds.height))")
                        emit("WARN crushed 工作中 h=\(Int(b.bounds.height))")
                    }
                }
                for c in v.subviews { walk(c) }
            }
            walk(chat.view)
        }
        RunLoop.main.add(timer, forMode: .common)
        return {
            timer.invalidate()
            return Array(Set(issues))
        }
    }

    private static func waitAgentIdle(
        chat: ChatViewController,
        timeout: TimeInterval,
        completion: @escaping (Bool) -> Void
    ) {
        let start = Date()
        var settleTicks = 0
        func tick() {
            if Date().timeIntervalSince(start) > timeout {
                completion(false)
                return
            }
            guard let conv = ConversationStore.shared.currentConversation else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: tick)
                return
            }
            let streaming = conv.messages.contains(where: \.isStreaming)
            let agentBusy = conv.messages.contains {
                $0.agentProcessPhase == .running || $0.agentProcessPhase == .waitingUser
            }
            if streaming || agentBusy {
                settleTicks = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: tick)
                return
            }
            settleTicks += 1
            // Require two consecutive idle samples (~1s) so tool-loop gaps don't false-complete.
            if settleTicks >= 2 {
                completion(true)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: tick)
            }
        }
        tick()
    }

    private static func run() {
        emit("begin live agent/plan suite")
        var failures: [String] = []
        DebugAPIBootstrap.loadDeepseekKeyIfNeeded(logTag: logTag)

        guard SettingsManager.shared.hasAPIKey(for: .deepseek) else {
            emit("FAIL missing DeepSeek API key")
            return
        }

        // Prefer DeepSeek V4 Flash for tool loops.
        SettingsManager.shared.thinkingEnabled = true // must still be forced off by workspace flag
        let model = AIModelOption.deepseekV4Flash

        let ws = StudyWorkspaceStore.shared.ensureDefault()
        let stamp = Int(Date().timeIntervalSince1970) % 100_000
        let aName = "live_a_\(stamp).swift"
        let bName = "live_b_\(stamp).swift"
        do {
            _ = try StudyWorkspaceStore.shared.createFile(
                named: aName,
                content: "func alpha() -> Int { return 1 }\n",
                in: ws.id
            )
            _ = try StudyWorkspaceStore.shared.createFile(
                named: bName,
                content: "func beta() -> Int { return 2 }\n",
                in: ws.id
            )
        } catch {
            emit("FAIL seed files: \(error)")
            return
        }

        let window = keyWindow()
        guard let root = window?.rootViewController,
              let chat = findChatVC(in: root) else {
            emit("FAIL chat VC not found")
            return
        }

        let firstDoc = StudyWorkspaceStore.shared.workspace(id: ws.id)?.documentIDs.first
        let conv = ConversationStore.shared.createConversation(
            model: model,
            studyWorkspaceID: ws.id,
            studyDocumentID: firstDoc,
            studySessionKind: .workspace,
            studyPageCaptureEnabled: false,
            studyAgentMode: .plan
        )
        ConversationStore.shared.updateConversation(id: conv.id) { draft in
            draft.title = "Agent Live QA"
            draft.titleLocked = true
        }
        chat.reloadChat()

        if let shell = findShell(in: root) {
            shell.view.layoutIfNeeded()
            shell.debugExpandChatPanel()
            shell.applyStudyChatPanelStage(.full, animated: false)
            shell.view.layoutIfNeeded()
        }
        chat.view.layoutIfNeeded()

        capture(chat.view, frame: "00_workspace_ready")

        // —— Plan turn ——
        let planPrompt = """
        用 Plan 模式规划：给 \(aName) 的 alpha 加注释；给 \(bName) 的 beta 加注释。
        必须 create_file 写出 connects_plan 的 md（含两个 `- [ ]` todos），不要长文聊天。
        """
        emit("send Plan turn")
        let stopPlanWatch = startFreezeWatch(chat: chat)
        chat.debugSendUserMessage(planPrompt, timeout: 240) { planSendOK in
            self.waitAgentIdle(chat: chat, timeout: 300) { planIdle in
                for issue in stopPlanWatch() {
                    failures.append("plan/\(issue)")
                }
                if let shell = self.findShell(in: root) {
                    shell.debugExpandChatPanel()
                    shell.applyStudyChatPanelStage(.full, animated: false)
                    shell.view.layoutIfNeeded()
                }
                chat.view.layoutIfNeeded()
                self.capture(chat.view, frame: "01_after_plan")
                if let window {
                    self.capture(window, frame: "01b_after_plan_window")
                }
                if !planSendOK && !planIdle {
                    failures.append("Plan turn did not finish")
                }
                let msgs = ConversationStore.shared.conversation(id: conv.id)?.messages ?? []
                let asst = msgs.filter { $0.role == .assistant && !$0.shouldHideInTranscript }
                let rootAsst = asst.first(where: { $0.hasAgentProcess }) ?? asst.last
                if let rootAsst {
                    let summary = rootAsst.agentProcessSummaryTitle
                    emit("plan summary=\(summary)")
                    if summary.contains("工作中") {
                        failures.append("plan still shows 工作中 after idle: \(summary)")
                    }
                }
                let names = StudyWorkspaceStore.shared.listFileNames(in: ws.id)
                emit("workspace files=\(names.joined(separator: ", "))")
                var foundPlan = false
                for name in names where name.hasSuffix(".md") {
                    if let folder = try? StudyWorkspaceStore.shared.folderURL(for: ws.id),
                       let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8),
                       StudyPlanDocument.parse(text).isPlan {
                        foundPlan = true
                        break
                    }
                }
                if !foundPlan {
                    failures.append("Plan did not create connects_plan md in workspace")
                }

                let chrome1 = self.chromeSnapshotLabels(in: chat.view)
                emit("chrome after plan: worked=\(chrome1.hasWorked) thinking=\(chrome1.hasThinking)")
                if chrome1.hasWorked && chrome1.hasThinking {
                    failures.append("已工作 and 深度思考 both visible after Plan (misaligned dual chrome)")
                }

                // —— Agent multi-file edit ——
                ConversationStore.shared.updateConversation(id: conv.id) { draft in
                    draft.studyAgentMode = .agent
                }
                chat.reloadChat()
                if let shell = self.findShell(in: root) {
                    shell.debugExpandChatPanel()
                    shell.applyStudyChatPanelStage(.full, animated: false)
                }
                let agentPrompt = """
                修改工作区两个文件：\(aName) 的 alpha 返回 10；\(bName) 的 beta 返回 20。
                必须用 propose_edit 分别改两个文件（每个文件一次），少旁白，先 list_dir / read_file 再改。
                """
                emit("send Agent multi-file turn")
                let stopAgentWatch = self.startFreezeWatch(chat: chat)
                chat.debugSendUserMessage(agentPrompt, timeout: 300) { agentSendOK in
                    self.waitAgentIdle(chat: chat, timeout: 360) { agentIdle in
                        for issue in stopAgentWatch() {
                            failures.append("agent/\(issue)")
                        }
                        if let shell = self.findShell(in: root) {
                            shell.debugExpandChatPanel()
                            shell.applyStudyChatPanelStage(.full, animated: false)
                            shell.view.layoutIfNeeded()
                        }
                        chat.view.layoutIfNeeded()
                        self.capture(chat.view, frame: "02_after_agent_edits")
                        if let window {
                            self.capture(window, frame: "02b_after_agent_window")
                        }
                        if !agentSendOK && !agentIdle {
                            failures.append("Agent turn did not finish")
                        }
                        let msgs2 = ConversationStore.shared.conversation(id: conv.id)?.messages ?? []
                        let asst2 = msgs2.filter { $0.role == .assistant && !$0.shouldHideInTranscript }
                        if let lastRoot = asst2.last(where: { $0.hasAgentProcess }) ?? asst2.last {
                            let summary = lastRoot.agentProcessSummaryTitle
                            emit("agent summary=\(summary)")
                            if lastRoot.agentProcessPhase == .running {
                                failures.append("agent phase still running after idle wait")
                            }
                        }
                        // Verify disk writes.
                        if let folder = try? StudyWorkspaceStore.shared.folderURL(for: ws.id) {
                            let aText = (try? String(contentsOf: folder.appendingPathComponent(aName), encoding: .utf8)) ?? ""
                            let bText = (try? String(contentsOf: folder.appendingPathComponent(bName), encoding: .utf8)) ?? ""
                            emit("file \(aName)=\(aText.replacingOccurrences(of: "\n", with: "⏎"))")
                            emit("file \(bName)=\(bText.replacingOccurrences(of: "\n", with: "⏎"))")
                            if !aText.contains("10") {
                                failures.append("\(aName) was not updated to return 10")
                            }
                            if !bText.contains("20") {
                                failures.append("\(bName) was not updated to return 20")
                            }
                        }
                        let chrome2 = self.chromeSnapshotLabels(in: chat.view)
                        emit("chrome after agent: worked=\(chrome2.hasWorked) thinking=\(chrome2.hasThinking)")
                        if chrome2.hasWorked && chrome2.hasThinking {
                            failures.append("已工作 and 深度思考 both visible after Agent")
                        }

                        chat.debugSimulateScrollUp(distance: 400) {
                            chat.view.layoutIfNeeded()
                            self.capture(chat.view, frame: "03_scrolled_multi_qa")
                            let chrome3 = self.chromeSnapshotLabels(in: chat.view)
                            if chrome3.hasWorked && chrome3.hasThinking {
                                failures.append("dual chrome visible after scroll")
                            }

                            if failures.isEmpty {
                                self.emit("PASS live agent/plan suite")
                            } else {
                                for f in failures { self.emit("FAIL \(f)") }
                                self.emit("FAIL live agent/plan suite (\(failures.count) issues)")
                            }
                            self.emit("PULL /tmp/connects_visual_qa via Scripts/pull-visual-qa.sh")
                        }
                    }
                }
            }
        }
    }
}
#endif
