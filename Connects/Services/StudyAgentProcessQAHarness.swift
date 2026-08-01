#if DEBUG
import UIKit

/// Visual / assertion QA for workspace Agent process chrome.
/// Launch: `-StudyAgentProcessQA`
/// Freeze stress (no network): `-AgentFreezeQA`
/// Frames: Documents/ConnectsVisualQA/agent_process/*.png
enum StudyAgentProcessQAHarness {
    private static let logTag = "[StudyAgentProcessQA]"
    private static var didRun = false
    private static let scenario = "agent_process"

    static func runIfRequested() {
        if ProcessInfo.processInfo.arguments.contains("-AgentFreezeQA") {
            guard !didRun else { return }
            didRun = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                runFreezeBurst()
            }
            return
        }
        guard ProcessInfo.processInfo.arguments.contains("-StudyAgentProcessQA")
            || ProcessInfo.processInfo.arguments.contains("-AgentTimelineVisualQA") else { return }
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

    private static func runFreezeBurst() {
        emit("begin agent freeze burst")
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?
            .rootViewController,
              let chat = findChatVC(in: root) else {
            emit("FAIL chat VC not found")
            exit(1)
        }
        let ws = StudyWorkspaceStore.shared.ensureDefault()
        let firstDoc = StudyWorkspaceStore.shared.workspace(id: ws.id)?.documentIDs.first
        let conv = ConversationStore.shared.createConversation(
            model: .deepseekV4Flash,
            studyWorkspaceID: ws.id,
            studyDocumentID: firstDoc,
            studySessionKind: .workspace,
            studyPageCaptureEnabled: false,
            studyAgentMode: .agent
        )
        ConversationStore.shared.updateConversation(id: conv.id) { draft in
            draft.title = "Freeze QA"
            draft.titleLocked = true
        }
        chat.reloadChat()
        chat.debugAgentFreezeBurst(iterations: 90) { issues in
            if issues.isEmpty {
                self.emit("PASS agent freeze burst (no stall / no crush)")
                exit(0)
            }
            for i in issues { self.emit("FAIL \(i)") }
            exit(1)
        }
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

    private static func run() {
        emit("begin agent process suite")
        var failures: [String] = []

        // 1) Step copy / summary assertions (no network).
        let steps: [AgentProcessStep] = [
            AgentProcessStep(kind: .exploring, title: "列出工作区文件", detail: "3 个文件", status: .done),
            AgentProcessStep(kind: .grepped, title: "搜索 \"TODO\"", detail: "2 处命中", status: .done),
            AgentProcessStep(kind: .read, title: "阅读 main.swift", detail: "已读 1.2k 字符", status: .done),
            AgentProcessStep(kind: .subagent, title: "扫一眼工作区", detail: "工作区约 3 个文件", status: .done),
            AgentProcessStep(kind: .edited, title: "提案编辑 notes.md", detail: "notes.md · 80 字符", status: .done)
        ]
        let msg = ChatMessage(
            role: .assistant,
            content: "这是最终回答。",
            agentProcessSteps: steps,
            agentProcessPhase: .done,
            agentProcessStartedAt: Date().addingTimeInterval(-125),
            agentEditCards: [
                AgentEditCard(
                    fileName: "notes.md",
                    additions: 4,
                    deletions: 2,
                    snippetMinus: "old line",
                    snippetPlus: "new line"
                )
            ]
        )
        let display = msg.agentProcessDisplayText
        let summary = msg.agentProcessSummaryTitle
        emit("summary=\(summary)")
        emit("display=\(display.replacingOccurrences(of: "\n", with: " | "))")

        let banned = ["list_dir", "spawn_subagent", "Working…", "工作中 ·"]
        for b in banned {
            if display.contains(b) || summary.contains(b) {
                failures.append("banned token in chrome: \(b)")
            }
        }
        if !summary.contains("已工作") {
            failures.append("summary missing 已工作: \(summary)")
        }
        if !summary.contains("Explored") && !summary.contains("search") {
            failures.append("summary missing Cursor aggregate: \(summary)")
        }
        // Cursor timeline lines (English).
        if display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failures.append("display empty")
        }

        // Running title is fixed「工作中」— no elapsed.
        let runningTitle = ChatMessage(
            role: .assistant,
            content: "",
            agentProcessPhase: .running,
            agentProcessStartedAt: Date().addingTimeInterval(-3)
        ).agentProcessSummaryTitle
        if runningTitle != "工作中" {
            failures.append("running title should be 工作中, got \(runningTitle)")
        }

        // Single-root tool turns expand for API without extra table messages.
        var rootWithTurns = ChatMessage(
            role: .assistant,
            content: "live round",
            isStreaming: true,
            agentProcessPhase: .running,
            agentProcessStartedAt: Date(),
            agentToolTurns: [
                AgentToolTurn(
                    assistantContent: "round0 with tools",
                    toolResults: "## TOOL_RESULTS\nok"
                )
            ],
            agentProseSegments: ["先看现有文档。"],
            agentEditCards: [
                AgentEditCard(fileName: "notes.md", additions: 4, deletions: 2,
                              snippetMinus: "old", snippetPlus: "new")
            ]
        )
        let expanded = ChatMessage.messagesWithExpandedAgentToolTurns([
            ChatMessage(role: .user, content: "调查结构"),
            rootWithTurns
        ])
        if expanded.count != 4 {
            failures.append("tool-turn expand expected 4 msgs, got \(expanded.count)")
        }
        if rootWithTurns.agentTimelineBody.contains("先看现有文档") != true {
            failures.append("timeline body missing prior prose")
        }
        if rootWithTurns.agentEditCards.first?.headerLine.contains("notes.md") != true {
            failures.append("edit card header missing")
        }
        _ = rootWithTurns

        // create_file store + StudyPlanDocument parse.
        let ws = StudyWorkspaceStore.shared.ensureDefault()
        let planMD = """
        ---
        connects_plan: true
        ---

        ## Todos
        - [ ] First
        - [x] Done
        """
        let parsed = StudyPlanDocument.parse(planMD)
        if !parsed.isPlan || parsed.todos.count != 2 || parsed.todos[0].done || !parsed.todos[1].done {
            failures.append("StudyPlanDocument parse failed")
        }
        let tmpName = "qa_plan_\(UUID().uuidString.prefix(6)).md"
        if let doc = try? StudyWorkspaceStore.shared.createFile(named: tmpName, content: planMD, in: ws.id) {
            if StudyDocumentStore.shared.textContent(for: doc.id)?.contains("connects_plan") != true {
                failures.append("create_file content missing frontmatter")
            }
            if let folder = try? StudyWorkspaceStore.shared.folderURL(for: ws.id) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(doc.title))
            }
        } else {
            failures.append("create_file store failed")
        }

        // Action buttons hidden while agent running.
        let running = ChatMessage(
            role: .assistant,
            content: "",
            agentProcessPhase: .running,
            agentProcessStartedAt: Date()
        )
        let runningShowsActions = running.agentProcessPhase != .running
            && running.agentProcessPhase != .waitingUser
            && !running.chatDisplayBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if runningShowsActions {
            failures.append("action buttons gate would show during agent run")
        }

        // Stream display must never leak open machine markers.
        let openToolRaw = """
        先看目录结构
        <<<CONNECTS_TOOL
        name: list_dir
        """
        let openToolDisplay = AgentTools.strippingToolBlocksForDisplay(from: openToolRaw)
        if openToolDisplay.contains("<<<") || openToolDisplay.localizedCaseInsensitiveContains("CONNECTS_TOOL") {
            failures.append("open TOOL marker leaked into display: \(openToolDisplay)")
        }
        if !openToolDisplay.contains("先看目录结构") {
            failures.append("open TOOL strip dropped prose")
        }
        let partialArrows = "意图说明\n<<<CONN"
        let partialDisplay = AgentTools.strippingToolBlocksForDisplay(from: partialArrows)
        if partialDisplay.contains("<<<") {
            failures.append("partial <<< leaked: \(partialDisplay)")
        }
        let openEditMsg = ChatMessage(
            role: .assistant,
            content: """
            准备改文件
            <<<CONNECTS_EDIT
            path: notes.md
            ```
            hello
            """,
            agentProcessPhase: .running,
            agentProcessStartedAt: Date()
        )
        let editVisible = openEditMsg.chatDisplayBodyCurrentRound
        if editVisible.contains("<<<") || editVisible.localizedCaseInsensitiveContains("CONNECTS_EDIT>>>") {
            failures.append("open EDIT marker leaked into chatDisplayBody: \(editVisible)")
        }
        let blocks = openEditMsg.agentInterleavedBlocks(liveOverlay: AgentProcessPhase.thinkingText)
        if blocks.contains(where: { $0.text.contains("<<<") }) {
            failures.append("interleaved blocks contain <<<")
        }
        _ = blocks

        // Orchestrator human titles for raw tool names.
        let listCall = AgentToolCall(name: .listDir, arguments: [:])
        let listMeta = AgentTools.humanStepTitle(for: listCall)
        if listMeta.title.contains("list_dir") {
            failures.append("list_dir title still noisy: \(listMeta.title)")
        }
        let createCall = AgentToolCall(name: .createFile, arguments: ["path": "plan.md"])
        let createMeta = AgentTools.humanStepTitle(for: createCall)
        if createMeta.kind != .created || !createMeta.title.contains("plan.md") {
            failures.append("create_file title wrong: \(createMeta.title)")
        }

        // Coalesce consecutive identical Read lines in interleaved blocks.
        let coalesceMsg = ChatMessage(
            role: .assistant,
            content: "",
            agentProcessSteps: [
                AgentProcessStep(kind: .read, title: "Reading foo.v", detail: "", status: .done),
                AgentProcessStep(kind: .read, title: "Reading foo.v", detail: "", status: .done),
                AgentProcessStep(kind: .read, title: "Reading foo.v", detail: "", status: .done)
            ],
            agentProcessPhase: .done,
            agentProcessStartedAt: Date().addingTimeInterval(-10)
        )
        let coalesced = coalesceMsg.agentInterleavedBlocks().filter { $0.isMeta && $0.text.contains("foo") }
        if coalesced.count != 1 || !coalesced[0].text.contains("×3") {
            failures.append("read coalesce failed: \(coalesced.map(\.text))")
        }

        // Patch propose_edit apply (unique old_string).
        let wsPatch = StudyWorkspaceStore.shared.ensureDefault()
        let patchName = "qa_patch_\(UUID().uuidString.prefix(6)).v"
        if let doc = try? StudyWorkspaceStore.shared.createFile(
            named: patchName,
            content: "module a;\nwire x;\nendmodule\n",
            in: wsPatch.id
        ) {
            let call = AgentToolCall(
                name: .proposeEdit,
                arguments: [
                    "path": patchName,
                    "old_string": "wire x;",
                    "new_string": "wire y;"
                ]
            )
            let result = AgentTools.execute(
                call,
                workspaceID: wsPatch.id,
                mode: .agent,
                activeFileName: patchName
            )
            if case .proposeEdit(_, let content) = result {
                if !content.contains("wire y;") || content.contains("wire x;") {
                    failures.append("patch propose_edit content wrong")
                }
            } else {
                failures.append("patch propose_edit did not return proposeEdit")
            }
            if let folder = try? StudyWorkspaceStore.shared.folderURL(for: wsPatch.id) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(doc.title))
            }
        } else {
            failures.append("patch fixture create failed")
        }

        // 2) Hidden continuation user bubble.
        let hiddenCont = ChatMessage(
            role: .user,
            content: "",
            apiContextPrefix: "## TOOL_RESULTS\n[list_dir]\na.swift",
            isHiddenInTranscript: true
        )
        let legacyCont = ChatMessage(
            role: .user,
            content: "（工具结果，继续）",
            apiContextPrefix: "## TOOL_RESULTS\nx"
        )
        let plainContinue = ChatMessage(
            role: .user,
            content: "继续",
            apiContextPrefix: "## TOOL_RESULTS\ny"
        )
        if !hiddenCont.shouldHideInTranscript {
            failures.append("flagged continuation not hidden")
        }
        if !legacyCont.shouldHideInTranscript {
            failures.append("legacy （工具结果，继续） not hidden")
        }
        if !plainContinue.shouldHideInTranscript {
            failures.append("继续+TOOL_RESULTS not hidden")
        }
        let realUser = ChatMessage(role: .user, content: "请帮我改代码")
        if realUser.shouldHideInTranscript {
            failures.append("real user wrongly hidden")
        }

        // 3) Present chrome cell gallery for screenshots (done + running + open marker).
        let host = UIViewController()
        host.view.backgroundColor = DSTheme.c.background

        func makeCell(for message: ChatMessage, y: CGFloat, height: CGFloat) -> AssistantMessageCell {
            let cell = AssistantMessageCell(style: .default, reuseIdentifier: nil)
            cell.frame = CGRect(x: 16, y: y, width: 700, height: height)
            cell.configure(with: message, preferredHeight: height - 20, layoutWidth: 680)
            cell.syncAgentProcessPresentation(with: message, layoutWidth: 680)
            host.view.addSubview(cell)
            return cell
        }

        let doneCell = makeCell(for: msg, y: 40, height: 360)

        var runningMsg = ChatMessage(
            role: .assistant,
            content: "先扫一眼目录",
            isStreaming: true,
            agentProcessSteps: [
                AgentProcessStep(kind: .exploring, title: "Listing files…", detail: "", status: .running)
            ],
            agentProcessPhase: .running,
            agentProcessStartedAt: Date().addingTimeInterval(-2),
            agentProseSegments: ["先扫一眼目录"]
        )
        runningMsg.content = ""
        let runningCell = makeCell(for: runningMsg, y: 420, height: 140)
        runningCell.syncAgentProcessPresentation(
            with: runningMsg,
            layoutWidth: 680,
            liveOverlayText: AgentProcessPhase.thinkingText
        )
        runningCell.keepAgentLiveShimmerAlive()

        // ask_user prompt must appear as ask part in the bubble (not toast-only).
        var askMsg = ChatMessage(
            role: .assistant,
            content: "",
            agentProcessSteps: [
                AgentProcessStep(kind: .asked, title: "Asking…", detail: "Asked a question", status: .done)
            ],
            agentProcessPhase: .waitingUser,
            agentProcessStartedAt: Date().addingTimeInterval(-5)
        )
        askMsg.appendAskPart("你希望 SPI 用 CPOL=0 还是 CPOL=1？请选择一种极性。")
        let askBlocks = askMsg.agentInterleavedBlocks()
        if !askBlocks.contains(where: { $0.id.hasPrefix("ask-") && $0.text.contains("CPOL") }) {
            failures.append("ask_user prompt missing from interleaved blocks: \(askBlocks.map(\.text))")
        }
        if askBlocks.contains(where: { $0.id == "waiting" }) {
            failures.append("waiting header should be omitted when ask part exists")
        }

        // Half-screen width — historically ghosted / jumped under narrow chat.
        let halfCell = AssistantMessageCell(style: .default, reuseIdentifier: nil)
        halfCell.frame = CGRect(x: 16, y: 760, width: 320, height: 200)
        halfCell.configure(with: runningMsg, preferredHeight: 180, layoutWidth: 300)
        halfCell.syncAgentProcessPresentation(
            with: runningMsg,
            layoutWidth: 300,
            liveOverlayText: AgentProcessPhase.thinkingText
        )
        halfCell.keepAgentLiveShimmerAlive()
        host.view.addSubview(halfCell)

        // ask_user fixture — full prompt visible in timeline.
        let askCell = AssistantMessageCell(style: .default, reuseIdentifier: nil)
        askCell.frame = CGRect(x: 16, y: 980, width: 700, height: 160)
        askCell.configure(with: askMsg, preferredHeight: 140, layoutWidth: 680)
        askCell.syncAgentProcessPresentation(with: askMsg, layoutWidth: 680)
        host.view.addSubview(askCell)

        // Scroll-reuse ghost check: paint → clear → paint again; no leftover shimmer layers.
        let reusePool = AssistantMessageCell(style: .default, reuseIdentifier: "reuse")
        reusePool.frame = CGRect(x: 16, y: 1160, width: 700, height: 120)
        reusePool.configure(with: runningMsg, preferredHeight: 100, layoutWidth: 680)
        reusePool.syncAgentProcessPresentation(
            with: runningMsg,
            layoutWidth: 680,
            liveOverlayText: AgentProcessPhase.thinkingText
        )
        reusePool.prepareForReuse()
        reusePool.configure(with: askMsg, preferredHeight: 100, layoutWidth: 680)
        reusePool.syncAgentProcessPresentation(with: askMsg, layoutWidth: 680)
        host.view.addSubview(reusePool)

        // Overlay must be stable Thinking / Planning — never ◐◓ spinner glyphs.
        var idleForOverlay = runningMsg
        idleForOverlay.agentProcessSteps = [
            AgentProcessStep(kind: .exploring, title: "Listing files…", detail: "Explored 1 file", status: .done)
        ]
        idleForOverlay.rebuildTimelinePartsFromLegacySources()
        let overlayBlocks = idleForOverlay.agentInterleavedBlocks(
            liveOverlay: AgentProcessPhase.thinkingText + "  ◐"
        )
        if overlayBlocks.contains(where: { $0.text.contains("◐") || $0.text.contains("◓") }) {
            failures.append("spinner glyph leaked into interleaved blocks")
        }
        if !overlayBlocks.contains(where: { $0.id == AgentTimelinePart.liveID && $0.text == AgentProcessPhase.thinkingText }) {
            failures.append("expected stable Thinking live overlay after glyph strip, got \(overlayBlocks.map(\.text))")
        }

        // Ordered parts (no step×prose zip): explore group then prose.
        let orderMsg = ChatMessage(
            role: .assistant,
            content: "",
            agentProcessSteps: [
                AgentProcessStep(kind: .read, title: "Reading a.v", detail: "", status: .done),
                AgentProcessStep(kind: .exploring, title: "Listing…", detail: "Explored 1", status: .done)
            ],
            agentProcessPhase: .running,
            agentProcessStartedAt: Date(),
            agentProseSegments: ["中间说明文字"]
        )
        let paint = orderMsg.agentTimelinePaintItems(defaultExploreExpanded: true)
        if paint.first(where: { $0.role == .exploreHeader }) == nil {
            failures.append("missing Explored group header: \(paint.map(\.text))")
        }
        if let proseIdx = paint.firstIndex(where: { $0.role == .prose }),
           let headerIdx = paint.firstIndex(where: { $0.role == .exploreHeader }),
           proseIdx < headerIdx {
            failures.append("prose before Explored header")
        }
        if !paint.contains(where: { $0.text.contains("中间说明文字") }) {
            failures.append("ordered parts missing prose")
        }

        // Chronological multi-round: Thought → Read → prose₁ → Deleted → prose₂
        // (must NOT bucket all tools before all prose).
        let chronoMsg = ChatMessage(
            role: .assistant,
            content: "",
            agentProcessPhase: .done,
            agentProcessStartedAt: Date().addingTimeInterval(-25),
            agentTimelineParts: [
                AgentTimelinePart(
                    id: "thought-chrono",
                    kind: .thinking,
                    text: "Thought for 1s",
                    stepKind: .thought,
                    detail: "先想再读"
                ),
                AgentTimelinePart(
                    id: "step-read-chrono",
                    kind: .meta,
                    text: "Reading a.v",
                    stepKind: .read
                ),
                AgentTimelinePart(id: "prose-mid-1", kind: .prose, text: "中间状态：已读完"),
                AgentTimelinePart(
                    id: "step-del-chrono",
                    kind: .meta,
                    text: "Deleted a.v",
                    stepKind: .deleted
                ),
                AgentTimelinePart(id: "prose-mid-2", kind: .prose, text: "清理完成")
            ]
        )
        let chronoPaint = chronoMsg.agentTimelinePaintItems(defaultExploreExpanded: true)
        let chronoThought = chronoPaint.firstIndex(where: { $0.stepKind == .thought })
        let chronoRead = chronoPaint.firstIndex(where: { $0.stepKind == .read })
        let chronoProse1 = chronoPaint.firstIndex(where: { $0.role == .prose && $0.text.contains("中间状态") })
        let chronoDeleted = chronoPaint.firstIndex(where: { $0.stepKind == .deleted })
        let chronoProse2 = chronoPaint.firstIndex(where: { $0.role == .prose && $0.text.contains("清理完成") })
        if let t = chronoThought, let r = chronoRead, let p1 = chronoProse1,
           let d = chronoDeleted, let p2 = chronoProse2 {
            if !(t < r && r < p1 && p1 < d && d < p2) {
                failures.append(
                    "chrono_multi_round order wrong: \(chronoPaint.map { "\($0.role.rawValue):\($0.text)" })"
                )
            }
        } else {
            failures.append(
                "chrono_multi_round missing roles: \(chronoPaint.map { "\($0.role.rawValue):\($0.text)" })"
            )
        }
        if let firstProse = chronoPaint.firstIndex(where: { $0.role == .prose }),
           let lastTool = chronoPaint.lastIndex(where: {
               $0.role == .exploreChild && ($0.stepKind == .read || $0.stepKind == .deleted || $0.stepKind == .thought)
           }),
           lastTool < firstProse {
            failures.append("chrono_multi_round bucketed all tools before all prose")
        }
        // Per-group expand: opening group 1 must not expand group 2.
        let onlyFirst = chronoMsg.agentTimelinePaintItems(
            defaultExploreExpanded: false,
            exploreExpandOverrides: [AgentTimelinePart.exploreHeaderID: true]
        )
        let headers = onlyFirst.filter { $0.role == .exploreHeader }.map(\.id)
        if headers.count >= 2 {
            let g1Kids = onlyFirst.contains(where: { $0.stepKind == .read || $0.stepKind == .thought })
            let g2Kids = onlyFirst.contains(where: { $0.stepKind == .deleted })
            if !g1Kids {
                failures.append("per-group expand: first Explored children missing")
            }
            if g2Kids {
                failures.append("per-group expand: second Explored incorrectly opened with first")
            }
        }

        // Early phase: running, no tools — Thinking only (no Exploring… dual head, no body).
        let earlyMsg = ChatMessage(
            role: .assistant,
            content: "终答正文不应出现",
            reasoningContent: "内部推理进行中",
            isStreaming: true,
            agentProcessPhase: .running,
            agentProcessStartedAt: Date()
        )
        let earlyPaint = earlyMsg.agentTimelinePaintItems(
            liveOverlay: AgentProcessPhase.thinkingText,
            defaultExploreExpanded: true
        )
        if earlyPaint.contains(where: { $0.role == .exploreHeader }) {
            failures.append("early_thinking_only: unexpected Explored header \(earlyPaint.map(\.text))")
        }
        if earlyPaint.contains(where: { $0.text.contains("Exploring") }) {
            failures.append("early_thinking_only: Exploring… dual head \(earlyPaint.map(\.text))")
        }
        if earlyPaint.contains(where: { $0.role == .prose }) {
            failures.append("early_thinking_only: prose leaked while running \(earlyPaint.map(\.text))")
        }
        if earlyPaint.filter({ $0.role == .live }).count != 1
            || earlyPaint.first(where: { $0.role == .live })?.text != AgentProcessPhase.thinkingText {
            failures.append("early_thinking_only: expected sole Thinking live \(earlyPaint.map(\.text))")
        }

        // Final prose only after done; Explored header above body.
        var finalHold = ChatMessage(
            role: .assistant,
            content: "最终回答：清理完成。",
            isStreaming: true,
            agentProcessSteps: [
                AgentProcessStep(kind: .read, title: "Reading a.v", detail: "", status: .done),
                AgentProcessStep(kind: .deleted, title: "Deleting a.v",
                                 detail: "Deleted a.v", status: .done)
            ],
            agentProcessPhase: .running,
            agentProcessStartedAt: Date().addingTimeInterval(-8)
        )
        let holdPaint = finalHold.agentTimelinePaintItems(
            liveOverlay: AgentProcessPhase.planningNextMovesText,
            defaultExploreExpanded: true
        )
        if holdPaint.contains(where: { $0.role == .prose && $0.text.contains("最终回答") }) {
            failures.append("final_prose_at_done: prose visible while still running")
        }
        finalHold.isStreaming = false
        finalHold.agentProcessPhase = .done
        let donePaint = finalHold.agentTimelinePaintItems(defaultExploreExpanded: false)
        if let doneHeader = donePaint.firstIndex(where: { $0.role == .exploreHeader }),
           let doneProse = donePaint.firstIndex(where: {
               $0.role == .prose && $0.text.contains("最终回答")
           }) {
            if doneProse < doneHeader {
                failures.append("final_prose_at_done: prose above Explored header")
            }
        } else {
            failures.append("final_prose_at_done missing header/prose: \(donePaint.map(\.text))")
        }

        // Thought seals under Explored; collapsed when done.
        var thoughtMsg = ChatMessage(
            role: .assistant,
            content: "最终回答多行\n第二行正文\n第三行",
            reasoningContent: "内部推理内容用于展开",
            agentProcessSteps: [
                AgentProcessStep(kind: .read, title: "Reading foo.swift", detail: "", status: .done)
            ],
            agentProcessPhase: .done,
            agentProcessStartedAt: Date().addingTimeInterval(-12)
        )
        thoughtMsg.sealThoughtFromReasoningIfNeeded()
        let collapsed = thoughtMsg.agentTimelinePaintItems(defaultExploreExpanded: false)
        if collapsed.contains(where: { $0.role == .exploreChild }) {
            failures.append("done turn should collapse Explored children by default")
        }
        if collapsed.first(where: { $0.role == .exploreHeader }) == nil {
            failures.append("done turn missing Explored header")
        }
        let expandedThought = thoughtMsg.agentTimelinePaintItems(defaultExploreExpanded: true)
        if !expandedThought.contains(where: {
            $0.stepKind == .thought && $0.detail.contains("内部推理")
        }) {
            failures.append("Thought detail missing under Explored: \(expandedThought.map(\.text))")
        }

        // Consecutive Updated plan coalesce.
        let planSpam = ChatMessage(
            role: .assistant,
            content: "",
            agentProcessSteps: [
                AgentProcessStep(kind: .planned, title: "Updating plan…", detail: "Updated plan", status: .done),
                AgentProcessStep(kind: .planned, title: "Updating plan…", detail: "Updated plan", status: .done),
                AgentProcessStep(kind: .planned, title: "Updating plan…", detail: "Updated plan", status: .done)
            ],
            agentProcessPhase: .done,
            agentProcessStartedAt: Date().addingTimeInterval(-30)
        )
        let planBlocks = planSpam.agentInterleavedBlocks().filter {
            $0.text.contains("Updated plan") || $0.text.lowercased().contains("plan")
        }
        if planBlocks.count > 1 {
            failures.append("planned steps not coalesced: \(planBlocks.map { $0.text })")
        }
        let planPaint = planSpam.agentTimelinePaintItems(defaultExploreExpanded: true)
        if planPaint.contains(where: { $0.role == .planned }) {
            failures.append("Updated plan must live inside Explored (not free-floating planned role)")
        }
        if !planPaint.contains(where: { $0.role == .exploreChild && $0.stepKind == .planned }) {
            failures.append("Updated plan missing as Explored child: \(planPaint.map(\.text))")
        }

        // delete_file tool — Agent only; hard delete; Cursor "Deleted …" chrome.
        let delName = "qa_del_\(UUID().uuidString.prefix(6)).v"
        if let doc = try? StudyWorkspaceStore.shared.createFile(
            named: delName,
            content: "module qa_del;\n// fixture for delete_file visual QA\nendmodule\n",
            in: ws.id
        ) {
            let delCall = AgentToolCall(name: .deleteFile, arguments: ["path": delName])
            let delMeta = AgentTools.humanStepTitle(for: delCall)
            if delMeta.kind != .deleted || !delMeta.title.contains(delName) {
                failures.append("delete_file title wrong: \(delMeta.title)")
            }
            let askDenied = AgentTools.execute(delCall, workspaceID: ws.id, mode: .ask, activeFileName: delName)
            if case .text(let t) = askDenied, !t.contains("error:") {
                failures.append("delete_file should fail in ask mode")
            }
            let planDenied = AgentTools.execute(delCall, workspaceID: ws.id, mode: .plan, activeFileName: delName)
            if case .text(let t) = planDenied, !t.contains("error:") {
                failures.append("delete_file should fail in plan mode")
            }
            let otherDenied = AgentTools.execute(
                delCall,
                workspaceID: ws.id,
                mode: .agent,
                activeFileName: "other_open.v"
            )
            if case .text(let t) = otherDenied, !t.contains("error:") {
                failures.append("delete_file should fail when not the open file")
            }
            let delResult = AgentTools.execute(delCall, workspaceID: ws.id, mode: .agent, activeFileName: delName)
            if case .text(let t) = delResult {
                if !t.lowercased().contains("deleted") {
                    failures.append("delete_file success text wrong: \(t)")
                }
            } else {
                failures.append("delete_file did not return text")
            }
            let detail = AgentTools.humanStepDetailSummary(for: delCall, result: delResult)
            if !detail.hasPrefix("Deleted") {
                failures.append("delete chrome detail wrong: \(detail)")
            }
            if let folder = try? StudyWorkspaceStore.shared.folderURL(for: ws.id) {
                let path = folder.appendingPathComponent(doc.title).path
                if FileManager.default.fileExists(atPath: path) {
                    failures.append("delete_file left file on disk")
                }
            }
        } else {
            failures.append("delete_file fixture create failed")
        }

        // WorkspaceAgentRuntime batch: propose_edit on the open file + flush → disk + session.
        let batchName = "qa_batch_\(UUID().uuidString.prefix(6)).v"
        let createBody = "module qa_batch;\n  wire a;\n  wire b;\nendmodule\n"
        let batchBlocked = AgentTools.execute(
            AgentToolCall(name: .createFile, arguments: ["path": batchName, "body": createBody]),
            workspaceID: ws.id,
            mode: .agent,
            activeFileName: "already_open.v"
        )
        if case .text(let t) = batchBlocked, !t.contains("error:") {
            failures.append("create_file should be blocked in Agent mode")
        } else if case .proposeEdit = batchBlocked {
            failures.append("create_file agent mode must not return proposeEdit")
        }
        if let batchDoc = try? StudyWorkspaceStore.shared.createFile(
            named: batchName,
            content: "module qa_batch;\n  wire a;\nendmodule\n",
            in: ws.id
        ) {
            let patchCall = AgentToolCall(
                name: .proposeEdit,
                arguments: [
                    "path": batchName,
                    "old_string": "wire a;",
                    "new_string": "wire a;\n  wire b;"
                ]
            )
            let createResult = AgentTools.execute(
                patchCall,
                workspaceID: ws.id,
                mode: .agent,
                activeFileName: batchName
            )
            if case .proposeEdit(let path, let body) = createResult {
                WorkspaceAgentRuntime.shared.beginEditBatch(
                    conversationID: "qa-batch",
                    rootMessageID: "qa-root",
                    workspaceID: ws.id
                )
                WorkspaceAgentRuntime.shared.enqueueProposedEdit(path: path, body: body)
                let flush = WorkspaceAgentRuntime.shared.flushEditBatch { _, _ in }
                if flush.mutatedDocumentIDs.isEmpty {
                    failures.append("agent runtime flush produced no mutated docs")
                }
                if WorkspaceEditSession.shared.pending(documentID: flush.mutatedDocumentIDs.first ?? "") == nil {
                    failures.append("agent runtime flush missing WorkspaceEditSession entry")
                }
                // Cross-file enqueue must no-op when conversation locks another open file.
                let otherName = "qa_other_\(UUID().uuidString.prefix(6)).v"
                if let otherDoc = try? StudyWorkspaceStore.shared.createFile(
                    named: otherName,
                    content: "module other;\nendmodule\n",
                    in: ws.id
                ),
                   let openConvID = ConversationStore.shared.currentConversationID {
                    ConversationStore.shared.updateConversation(id: openConvID) { draft in
                        draft.studyDocumentID = batchDoc.id
                        draft.studyWorkspaceID = ws.id
                        draft.studySessionKind = .workspace
                    }
                    WorkspaceAgentRuntime.shared.beginEditBatch(
                        conversationID: openConvID,
                        rootMessageID: "qa-root-2",
                        workspaceID: ws.id
                    )
                    WorkspaceAgentRuntime.shared.enqueueProposedEdit(
                        path: otherName,
                        body: "module other;\n  // should not write\nendmodule\n"
                    )
                    let blockedFlush = WorkspaceAgentRuntime.shared.flushEditBatch { _, _ in }
                    if blockedFlush.mutatedDocumentIDs.contains(otherDoc.id) {
                        failures.append("runtime wrote a non-open file")
                    }
                    if let folder = try? StudyWorkspaceStore.shared.folderURL(for: ws.id) {
                        try? FileManager.default.removeItem(at: folder.appendingPathComponent(otherName))
                    }
                }
                if let folder = try? StudyWorkspaceStore.shared.folderURL(for: ws.id) {
                    let disk = folder.appendingPathComponent(batchName)
                    if !FileManager.default.fileExists(atPath: disk.path) {
                        failures.append("propose_edit+runtime left no disk file")
                    }
                    try? FileManager.default.removeItem(at: disk)
                }
                for id in flush.mutatedDocumentIDs {
                    WorkspaceEditSession.shared.remove(documentID: id)
                }
            } else {
                failures.append("propose_edit agent mode did not return proposeEdit: \(createResult)")
            }
        } else {
            failures.append("batch fixture create failed")
        }

        // Ritual skip must continue (not end turn) so Agent can still mutate.
        let ritualCID = "qa-ritual-\(UUID().uuidString.prefix(6))"
        AgentOrchestrator.shared.resetTurnDedup(for: ritualCID)
        var ritualContinued = false
        var ritualChunks = ""
        // Prime listed state via a successful list_dir round.
        _ = AgentOrchestrator.shared.handleAssistantFinished(
            conversationID: ritualCID,
            assistantMessageID: "a1",
            content: """
            <<<CONNECTS_TOOL
            name: list_dir
            CONNECTS_TOOL>>>
            """,
            workspaceID: ws.id,
            mode: .agent,
            appendStep: { _ in },
            updateStep: { _ in },
            onProposeEdit: { _, _ in },
            requestContinuation: { _ in }
        )
        ritualContinued = AgentOrchestrator.shared.handleAssistantFinished(
            conversationID: ritualCID,
            assistantMessageID: "a2",
            content: """
            <<<CONNECTS_TOOL
            name: spawn_subagent
            role: explore
            task: look around again
            CONNECTS_TOOL>>>
            """,
            workspaceID: ws.id,
            mode: .agent,
            appendStep: { _ in },
            updateStep: { _ in },
            onProposeEdit: { _, _ in },
            requestContinuation: { chunk in
                ritualChunks = chunk
            }
        )
        if !ritualContinued {
            failures.append("ritual explore skip ended turn instead of continuing")
        }
        if !ritualChunks.lowercased().contains("skipped") {
            failures.append("ritual explore skip missing skipped TOOL_RESULTS")
        }
        AgentOrchestrator.shared.endTurnDedup(for: ritualCID)

        let leakMsg = ChatMessage(
            role: .assistant,
            content: """
            准备调用工具
            <<<CONNECTS_TOOL
            name: list_dir
            """,
            isStreaming: true,
            agentProcessPhase: .running,
            agentProcessStartedAt: Date()
        )
        let leakCell = makeCell(for: leakMsg, y: 580, height: 120)
        leakCell.syncAgentProcessPresentation(
            with: leakMsg,
            layoutWidth: 680,
            liveOverlayText: AgentProcessPhase.planningNextMovesText
        )
        if leakMsg.chatDisplayBodyCurrentRound.contains("<<<") {
            failures.append("visual leakMsg still has <<< in display body")
        }
        // Done fixture with cards must not still list edit as plain meta.
        let doneBlocks = msg.agentInterleavedBlocks()
        if doneBlocks.contains(where: { $0.text.contains("notes.md · 80") }) {
            failures.append("edit step still plain meta while edit card present")
        }

        // Also assert a list of transcript rows would skip hidden.
        let transcript = [
            ChatMessage(role: .user, content: "帮我看看"),
            msg,
            legacyCont,
            ChatMessage(role: .assistant, content: "续跑后的答案")
        ]
        let visible = transcript.filter { !$0.shouldHideInTranscript }
        if visible.contains(where: { $0.content.contains("工具结果") }) {
            failures.append("visible transcript still has 工具结果")
        }
        if visible.count != 3 {
            failures.append("expected 3 visible messages, got \(visible.count)")
        }

        let nav = UINavigationController(rootViewController: host)
        nav.modalPresentationStyle = .fullScreen
        guard let root = keyWindow()?.rootViewController else {
            emit("FAIL no root")
            finish(failures: failures)
            return
        }
        var presenter = root
        while let p = presenter.presentedViewController { presenter = p }
        // Dedicated visual frames: explore collapse/expand, thought, reopen, half width.
        var exploreFixture = ChatMessage(
            role: .assistant,
            content: "清理完成，已删除多余的 .v 文件。",
            reasoningContent: "先列目录，再逐个 delete_file，避免清空代替删除。",
            agentProcessSteps: [
                AgentProcessStep(kind: .exploring, title: "Listing files…",
                                 detail: "Explored 3 files", status: .done),
                AgentProcessStep(kind: .read, title: "Reading a.v", detail: "", status: .done),
                AgentProcessStep(kind: .deleted, title: "Deleting a.v",
                                 detail: "Deleted a.v", status: .done),
                AgentProcessStep(kind: .planned, title: "Updating plan…",
                                 detail: "Updated plan", status: .done)
            ],
            agentProcessPhase: .done,
            agentProcessStartedAt: Date().addingTimeInterval(-40)
        )
        exploreFixture.rebuildTimelinePartsFromLegacySources()
        exploreFixture.sealThoughtFromReasoningIfNeeded()
        let thoughtPartID = exploreFixture.timelinePartsForPaint()
            .first(where: { $0.stepKind == .thought || $0.kind == .thinking })?.id

        let exploreCollapsedCell = AssistantMessageCell(style: .default, reuseIdentifier: nil)
        exploreCollapsedCell.frame = CGRect(x: 16, y: 1320, width: 700, height: 220)
        exploreCollapsedCell.configure(with: exploreFixture, preferredHeight: 200, layoutWidth: 680)
        exploreCollapsedCell.qaPaintAgentTimeline(
            message: exploreFixture, layoutWidth: 680, exploreExpanded: false
        )
        exploreCollapsedCell.qaSizeToFittedHeight()
        host.view.addSubview(exploreCollapsedCell)

        let exploreExpandedCell = AssistantMessageCell(style: .default, reuseIdentifier: nil)
        exploreExpandedCell.frame = CGRect(x: 16, y: 1560, width: 700, height: 320)
        exploreExpandedCell.configure(with: exploreFixture, preferredHeight: 300, layoutWidth: 680)
        exploreExpandedCell.qaPaintAgentTimeline(
            message: exploreFixture, layoutWidth: 680, exploreExpanded: true
        )
        exploreExpandedCell.qaSizeToFittedHeight()
        host.view.addSubview(exploreExpandedCell)

        let thoughtExpandedCell = AssistantMessageCell(style: .default, reuseIdentifier: nil)
        thoughtExpandedCell.frame = CGRect(x: 16, y: 1900, width: 700, height: 360)
        thoughtExpandedCell.configure(with: exploreFixture, preferredHeight: 340, layoutWidth: 680)
        var thoughtIDs = Set<String>()
        if let tid = thoughtPartID { thoughtIDs.insert(tid) }
        thoughtExpandedCell.qaPaintAgentTimeline(
            message: exploreFixture,
            layoutWidth: 680,
            exploreExpanded: true,
            thoughtExpandedIDs: thoughtIDs
        )
        thoughtExpandedCell.qaSizeToFittedHeight()
        host.view.addSubview(thoughtExpandedCell)

        // Cold reopen: Codable round-trip then configure (overlap regression).
        var reopenMsg = exploreFixture
        reopenMsg.ensureTimelinePartsPopulated()
        let reopenCell = AssistantMessageCell(style: .default, reuseIdentifier: nil)
        reopenCell.frame = CGRect(x: 16, y: 2280, width: 700, height: 360)
        do {
            let data = try JSONEncoder().encode(reopenMsg)
            let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
            reopenCell.configure(with: decoded, preferredHeight: 340, layoutWidth: 680)
            reopenCell.qaPaintAgentTimeline(
                message: decoded, layoutWidth: 680, exploreExpanded: true
            )
            reopenCell.qaSizeToFittedHeight()
            if !reopenCell.qaIsAssistantLabelSuppressed {
                failures.append("reopen_overlap: assistantLabel still painting with timeline")
            }
        } catch {
            failures.append("reopen_overlap encode/decode failed: \(error.localizedDescription)")
        }
        host.view.addSubview(reopenCell)

        let halfExploreCell = AssistantMessageCell(style: .default, reuseIdentifier: nil)
        halfExploreCell.frame = CGRect(x: 16, y: 2660, width: 320, height: 280)
        halfExploreCell.configure(with: exploreFixture, preferredHeight: 260, layoutWidth: 300)
        halfExploreCell.qaPaintAgentTimeline(
            message: exploreFixture, layoutWidth: 300, exploreExpanded: true
        )
        halfExploreCell.qaSizeToFittedHeight()
        host.view.addSubview(halfExploreCell)

        let chronoCell = AssistantMessageCell(style: .default, reuseIdentifier: nil)
        chronoCell.frame = CGRect(x: 16, y: 2980, width: 700, height: 360)
        chronoCell.configure(with: chronoMsg, preferredHeight: 340, layoutWidth: 680)
        chronoCell.qaPaintAgentTimeline(
            message: chronoMsg, layoutWidth: 680, exploreExpanded: true
        )
        chronoCell.qaSizeToFittedHeight()
        host.view.addSubview(chronoCell)

        let earlyCell = AssistantMessageCell(style: .default, reuseIdentifier: nil)
        earlyCell.frame = CGRect(x: 16, y: 3360, width: 700, height: 160)
        earlyCell.configure(with: earlyMsg, preferredHeight: 140, layoutWidth: 680)
        earlyCell.syncAgentProcessPresentation(
            with: earlyMsg,
            layoutWidth: 680,
            liveOverlayText: AgentProcessPhase.thinkingText
        )
        earlyCell.qaSizeToFittedHeight()
        host.view.addSubview(earlyCell)

        var finalDoneMsg = finalHold
        finalDoneMsg.isStreaming = false
        finalDoneMsg.agentProcessPhase = .done
        let finalDoneCell = AssistantMessageCell(style: .default, reuseIdentifier: nil)
        finalDoneCell.frame = CGRect(x: 16, y: 3540, width: 700, height: 260)
        finalDoneCell.configure(with: finalDoneMsg, preferredHeight: 240, layoutWidth: 680)
        finalDoneCell.qaPaintAgentTimeline(
            message: finalDoneMsg, layoutWidth: 680, exploreExpanded: false
        )
        finalDoneCell.qaSizeToFittedHeight()
        host.view.addSubview(finalDoneCell)

        if exploreCollapsedCell.qaAgentTimelineChildCount > 0 {
            failures.append("explore_collapsed still shows child rows")
        }
        if exploreExpandedCell.qaAgentTimelineChildCount < 2 {
            failures.append("explore_expanded missing Thought/Read/Deleted children")
        }

        presenter.present(nav, animated: false) {
            host.view.layoutIfNeeded()
            doneCell.layoutIfNeeded()
            runningCell.layoutIfNeeded()
            leakCell.layoutIfNeeded()
            exploreCollapsedCell.layoutIfNeeded()
            exploreExpandedCell.layoutIfNeeded()
            thoughtExpandedCell.layoutIfNeeded()
            reopenCell.layoutIfNeeded()
            halfExploreCell.layoutIfNeeded()
            chronoCell.layoutIfNeeded()
            earlyCell.layoutIfNeeded()
            finalDoneCell.layoutIfNeeded()
            self.capture(host.view, frame: "01_agent_process_chrome")
            self.capture(doneCell, frame: "03_done_with_edit_card")
            self.capture(runningCell, frame: "04_running_thinking_shimmer")
            self.capture(leakCell, frame: "05_open_tool_no_leak")
            self.capture(halfCell, frame: "06_half_width_thinking_shimmer")
            self.capture(askCell, frame: "07_ask_user_prompt_in_bubble")
            self.capture(reusePool, frame: "08_reuse_after_scroll_clear")
            self.capture(exploreCollapsedCell, frame: "explore_collapsed")
            self.capture(exploreExpandedCell, frame: "explore_expanded")
            self.capture(thoughtExpandedCell, frame: "thought_expanded")
            self.capture(reopenCell, frame: "reopen_overlap")
            self.capture(halfExploreCell, frame: "half_width")
            self.capture(chronoCell, frame: "chrono_multi_round")
            self.capture(earlyCell, frame: "early_thinking_only")
            self.capture(finalDoneCell, frame: "final_prose_at_done")

            if failures.isEmpty {
                self.emit("PASS step copy CN")
                self.emit("PASS hidden TOOL_RESULTS user bubbles")
                self.emit("PASS single-root agentToolTurns expand")
                self.emit("PASS visual edit-card + no-marker leak")
                self.emit("PASS no spinner glyph / plan coalesce / half-width chrome")
                self.emit("PASS ordered timeline parts + ask_user in bubble")
                self.emit("PASS delete_file + Explored expand / reopen frames")
                self.emit("PASS chrono_multi_round + early_thinking_only + final_prose_at_done")
                self.emit("PASS agent mutate runtime + ritual continue")
            }
            // Keep on screen briefly so simctl screenshot can catch the gallery.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                nav.dismiss(animated: false) {
                    self.finish(failures: failures)
                }
            }
        }
    }

    private static func finish(failures: [String]) {
        if failures.isEmpty {
            emit("PASS agent process suite")
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
