#if DEBUG
import UIKit

/// Mac SPI empty-folder E2E (full-screen + half-screen AI).
/// Launch: `-StudyAgentSPIE2E`
/// Optional: `-SPIWorkspace=/absolute/path` (defaults to newest ~/Documents/ConnectsSPI_E2E_*)
enum StudyAgentSPIE2EHarness {
    private static let logTag = "[StudyAgentSPIE2E]"
    private static var didRun = false
    private static let scenario = "agent_spi_e2e"

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-StudyAgentSPIE2E") else { return }
        guard !didRun else { return }
        didRun = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
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

    private static func resolveSPIFolder() -> URL? {
        if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("-SPIWorkspace=") }) {
            let path = String(arg.dropFirst("-SPIWorkspace=".count))
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let docs = home.appendingPathComponent("Documents")
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: docs,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let matches = contents.filter { $0.lastPathComponent.hasPrefix("ConnectsSPI_E2E_") }
        return matches.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }.first
    }

    private static func waitAgentIdle(chat: ChatViewController, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let start = Date()
        var settle = 0
        func tick() {
            if Date().timeIntervalSince(start) > timeout {
                completion(false)
                return
            }
            guard let conv = ConversationStore.shared.currentConversation else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: tick)
                return
            }
            let busy = conv.messages.contains {
                $0.isStreaming || $0.agentProcessPhase == .running || $0.agentProcessPhase == .waitingUser
            }
            if busy {
                settle = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: tick)
                return
            }
            settle += 1
            if settle >= 2 {
                completion(true)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: tick)
            }
        }
        tick()
    }

    private static func run() {
        emit("begin SPI E2E (full + half screen)")
        var failures: [String] = []
        DebugAPIBootstrap.loadDeepseekKeyIfNeeded(logTag: logTag)
        guard SettingsManager.shared.hasAPIKey(for: .deepseek) else {
            emit("FAIL missing DeepSeek API key")
            exit(1)
        }

        // Always use an in-app empty folder (sandbox-writable). External bookmarks
        // are flaky for Mac Catalyst writes during automated E2E.
        let stamp = Int(Date().timeIntervalSince1970) % 100_000
        let ws: StudyWorkspace
        do {
            ws = try StudyWorkspaceStore.shared.createFolderWorkspace(name: "SPI_E2E_\(stamp)")
            _ = try StudyWorkspaceStore.shared.createFile(
                named: "AGENT_BRIEF.md",
                content: """
                # SPI E2E
                Build: SPI master → slave → 4 modes/LSB/PLL → async FIFO + UART uplink.
                Use small tasks + spawn_subagent; patch edits only.
                """,
                in: ws.id
            )
            if let folder = try? StudyWorkspaceStore.shared.folderURL(for: ws.id) {
                emit("workspace=\(folder.path)")
            } else {
                emit("workspace=in-app \(ws.title)")
            }
        } catch {
            emit("FAIL createFolderWorkspace: \(error)")
            exit(1)
        }

        guard let root = UIApplication.connectsKeyWindow?.rootViewController,
              let chat = findChatVC(in: root) else {
            emit("FAIL chat VC not found")
            exit(1)
        }

        let model = AIModelOption.deepseekV4Flash
        let firstDoc = StudyWorkspaceStore.shared.workspace(id: ws.id)?.documentIDs.first
        let conv = ConversationStore.shared.createConversation(
            model: model,
            studyWorkspaceID: ws.id,
            studyDocumentID: firstDoc,
            studySessionKind: .workspace,
            studyPageCaptureEnabled: false,
            studyAgentMode: .agent
        )
        ConversationStore.shared.updateConversation(id: conv.id) { draft in
            draft.title = "SPI E2E"
            draft.titleLocked = true
        }
        chat.reloadChat()

        let shell = findShell(in: root)
        shell?.debugExpandChatPanel()
        shell?.applyStudyChatPanelStage(.full, animated: false)
        chat.view.layoutIfNeeded()
        capture(chat.view, frame: "00_full_ready")

                let masterPrompt = """
                空文件夹任务第 1 步：写一个 SPI 主机模块（Verilog/SystemVerilog）。
                必须发出真实的 <<<CONNECTS_TOOL 块：先 update_plan，再 create_file 创建 spi_master.sv（body 里写完整模块）。
                禁止只用 Markdown 叙述「已创建」；短回复。
                """
        emit("send full-screen SPI master")
        chat.debugSendUserMessage(masterPrompt, timeout: 360) { ok in
            self.waitAgentIdle(chat: chat, timeout: 420) { idle in
                chat.view.layoutIfNeeded()
                self.capture(chat.view, frame: "01_full_after_master")
                if !ok && !idle { failures.append("full master turn incomplete") }
                let names1 = StudyWorkspaceStore.shared.listFileNames(in: ws.id)
                self.emit("files after master=\(names1.joined(separator: ", "))")
                if names1.filter({ $0 != "AGENT_BRIEF.md" }).isEmpty {
                    failures.append("no HDL files created after master turn")
                }

                // Half-screen AI
                shell?.applyStudyChatPanelStage(.half, animated: false)
                shell?.view.layoutIfNeeded()
                chat.view.layoutIfNeeded()
                self.capture(chat.view, frame: "02_half_ready")

                let slavePrompt = """
                第 2 步：写 SPI 从机模块（可新文件或补丁已有文件）。
                继续用小任务 + spawn_subagent；propose_edit 优先 old_string/new_string。
                """
                self.emit("send half-screen SPI slave")
                chat.debugSendUserMessage(slavePrompt, timeout: 360) { ok2 in
                    self.waitAgentIdle(chat: chat, timeout: 420) { idle2 in
                        chat.view.layoutIfNeeded()
                        self.capture(chat.view, frame: "03_half_after_slave")
                        if let window = UIApplication.connectsKeyWindow {
                            self.capture(window, frame: "03b_half_window")
                        }
                        if !ok2 && !idle2 { failures.append("half slave turn incomplete") }
                        let names2 = StudyWorkspaceStore.shared.listFileNames(in: ws.id)
                        self.emit("files after slave=\(names2.joined(separator: ", "))")
                        if names2.filter({ $0 != "AGENT_BRIEF.md" }).isEmpty {
                            failures.append("still no project files after slave")
                        }

                        let modesPrompt = """
                        第 3 步：适配 SPI 四种模式（CPOL/CPHA）、LSB first、PLL 时钟相关接口/注释。
                        用补丁改已有文件，不要整文件覆盖。
                        """
                        self.emit("send half-screen modes/LSB/PLL")
                        chat.debugSendUserMessage(modesPrompt, timeout: 360) { ok3 in
                            self.waitAgentIdle(chat: chat, timeout: 420) { idle3 in
                                chat.view.layoutIfNeeded()
                                self.capture(chat.view, frame: "04_half_after_modes")
                                if !ok3 && !idle3 { failures.append("modes turn incomplete") }

                                shell?.applyStudyChatPanelStage(.full, animated: false)
                                shell?.view.layoutIfNeeded()
                                chat.view.layoutIfNeeded()
                                self.capture(chat.view, frame: "05_full_before_fifo")

                                let fifoPrompt = """
                                第 4 步：写异步 FIFO，并写 UART 上行（SPI 数据到上位机）。短回复，小任务拆分。
                                """
                                self.emit("send full-screen FIFO/UART")
                                chat.debugSendUserMessage(fifoPrompt, timeout: 420) { ok4 in
                                    self.waitAgentIdle(chat: chat, timeout: 480) { idle4 in
                                        chat.view.layoutIfNeeded()
                                        self.capture(chat.view, frame: "06_full_after_fifo")
                                        if let window = UIApplication.connectsKeyWindow {
                                            self.capture(window, frame: "06b_full_window")
                                        }
                                        if !ok4 && !idle4 { failures.append("fifo/uart turn incomplete") }
                                        let names4 = StudyWorkspaceStore.shared.listFileNames(in: ws.id)
                                        self.emit("files final=\(names4.joined(separator: ", "))")
                                        let lower = names4.map { $0.lowercased() }.joined(separator: " ")
                                        let hasSPISignal = lower.contains("spi") || lower.contains("fifo") || lower.contains("uart")
                                            || names4.contains(where: { $0.hasSuffix(".v") || $0.hasSuffix(".sv") || $0.hasSuffix(".vhd") })
                                        if !hasSPISignal {
                                            failures.append("final workspace missing SPI/FIFO/UART/HDL files")
                                        }
                                        if let folder = try? StudyWorkspaceStore.shared.folderURL(for: ws.id) {
                                            let hdl = names4.filter {
                                                $0.hasSuffix(".v") || $0.hasSuffix(".sv") || $0.hasSuffix(".vhd")
                                            }
                                            let nonempty = hdl.filter { name in
                                                let url = folder.appendingPathComponent(name)
                                                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                                                return size >= 40
                                            }
                                            self.emit("hdl nonempty=\(nonempty.count)/\(hdl.count)")
                                            if nonempty.count < 3 {
                                                failures.append("expected ≥3 nonempty HDL files, got \(nonempty.count)")
                                            }
                                        }

                                        let asst = ConversationStore.shared.conversation(id: conv.id)?.messages
                                            .filter { $0.role == .assistant } ?? []
                                        for m in asst {
                                            if m.chatDisplayBody.contains("<<<") {
                                                failures.append("marker leak in display body")
                                                break
                                            }
                                        }

                                        if failures.isEmpty {
                                            self.emit("PASS SPI E2E full+half (master→slave→modes→fifo/uart)")
                                            exit(0)
                                        }
                                        for f in failures { self.emit("FAIL \(f)") }
                                        exit(1)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
#endif
