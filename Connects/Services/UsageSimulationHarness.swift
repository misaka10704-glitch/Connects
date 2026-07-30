import UIKit

#if DEBUG
/// Full tool-coverage simulation: chat, thinking, web search, Study PDF capture, image upload, fork, scroll.
/// Launch: `-UsageSimulation`
enum UsageSimulationHarness {
    private static let logTag = "[ConnectsUsageSim]"
    private static var didStart = false

    private struct Scenario {
        let id: String
        let prompt: String
        var imageBase64: String?
        var studyCaptureEnabled: Bool?
        var thinking: Bool?
        var webSearch: Bool?
        var requireReasoning = false
        var requireSearch = false
        var requireUserImage = false
        var timeout: TimeInterval = 180
    }

    private struct ToolResult {
        let id: String
        let ok: Bool
        let detail: String
    }

    static func startIfRequested(from chat: ChatViewController) {
        guard ProcessInfo.processInfo.arguments.contains("-UsageSimulation") else { return }
        guard !didStart else { return }
        didStart = true
        DebugAPIBootstrap.loadKimiKeyIfNeeded(logTag: logTag)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            run(on: chat)
        }
    }

    private static func run(on chat: ChatViewController) {
        guard SettingsManager.shared.hasAPIKey(for: .kimi) else {
            print("\(logTag) FAIL missing Kimi API key")
            finish(exitCode: 1)
            return
        }

        print("\(logTag) begin full tool coverage")
        chat.loadViewIfNeeded()
        let conv = ConversationStore.shared.createConversation(model: .kimi26)
        chat.applyConversationSwitchHint()
        chat.switchToConversation(id: conv.id, coldLaunch: true)
        chat.reloadChat()

        let savedThinking = SettingsManager.shared.thinkingEnabled
        let savedSearch = SettingsManager.shared.webSearchEnabled
        SettingsManager.shared.thinkingEnabled = false
        SettingsManager.shared.webSearchEnabled = false

        let issues: [RenderAuditChecks.Issue] = []
        let toolResults: [ToolResult] = []

        let scenarios: [Scenario] = [
            Scenario(
                id: "plain-chat-tex",
                prompt: "用 Markdown+TeX 简述四变量卡诺图化简步骤，含一个块级公式。"
            ),
            Scenario(
                id: "deep-thinking",
                prompt: "请逐步推导：证明 \\(\\sqrt{2}\\) 是无理数。",
                thinking: true,
                webSearch: false,
                requireReasoning: true,
                timeout: 240
            ),
            Scenario(
                id: "web-search",
                prompt: "2024年诺贝尔物理学奖得主是谁？请给出姓名并一句话说明贡献。",
                thinking: false,
                webSearch: true,
                requireSearch: true,
                timeout: 240
            ),
            Scenario(
                id: "image-upload",
                prompt: "请读出图片中的公式并解释欧姆定律。",
                imageBase64: makeTestImageBase64(label: "V = I × R"),
                studyCaptureEnabled: false,
                thinking: false,
                webSearch: false,
                requireUserImage: true,
                timeout: 240
            ),
            Scenario(
                id: "fork-chat",
                prompt: "用一句话总结我们上面讨论过的主题。",
                thinking: false,
                webSearch: false,
                timeout: 120
            )
        ]

        runScenarios(scenarios, index: 0, chat: chat, issues: issues, toolResults: toolResults) { issues, toolResults in
            runStudyCaptureScenario(
                id: "study-pdf-electronics",
                pdfPath: "/Users/misaka10704/Documents/Workspace/Engineer_Tex/在读/Electronics/电子技术（数字）_康华光.pdf",
                prompt: "我附上了当前阅读页截图。请描述本页主要内容，若是电路或真值表请简要说明。",
                chat: chat,
                issues: issues,
                toolResults: toolResults
            ) { issues, toolResults in
                runStudyCaptureScenario(
                    id: "study-pdf-music",
                    pdfPath: "/Users/misaka10704/Documents/Workspace/Engineer_Tex/在读/乐谱/After all.pdf",
                    prompt: "请根据附带乐谱页截图，说明可能的和弦进行与调性线索。",
                    chat: chat,
                    issues: issues,
                    toolResults: toolResults
                ) { issues, toolResults in
                    var finalIssues = issues
                    chat.debugSetStudyCaptureEnabled(false)
                    SettingsManager.shared.thinkingEnabled = savedThinking
                    SettingsManager.shared.webSearchEnabled = savedSearch
                    finalIssues.append(contentsOf: auditFontSizes())
                    runScrollCheck(on: chat) { scrollIssues in
                        finalIssues.append(contentsOf: scrollIssues)
                        report(issues: finalIssues, tools: toolResults)
                        let toolFailed = toolResults.contains { !$0.ok }
                        let scrollFailed = !scrollIssues.isEmpty
                        finish(exitCode: (toolFailed || scrollFailed) ? 1 : 0)
                    }
                }
            }
        }
    }

    private static func runScenarios(
        _ scenarios: [Scenario],
        index: Int,
        chat: ChatViewController,
        issues: [RenderAuditChecks.Issue],
        toolResults: [ToolResult],
        completion: @escaping ([RenderAuditChecks.Issue], [ToolResult]) -> Void
    ) {
        guard index < scenarios.count else {
            completion(issues, toolResults)
            return
        }
        let step = scenarios[index]
        if step.id == "fork-chat" {
            if let id = ConversationStore.shared.currentConversationID {
                _ = ConversationStore.shared.forkConversation(id: id)
                chat.reloadChat()
            }
        }
        applyToolToggles(step)
        print("\(logTag) send \(index + 1)/\(scenarios.count): \(step.id)")
        chat.debugSendUserMessage(
            step.prompt,
            imageBase64: step.imageBase64,
            studyCaptureEnabled: step.studyCaptureEnabled,
            timeout: step.timeout
        ) { ok in
            var nextIssues = issues
            var nextTools = toolResults
            if !ok {
                nextIssues.append(RenderAuditChecks.Issue(caseID: step.id, kind: "stream", detail: "timeout or failed"))
                nextTools.append(ToolResult(id: step.id, ok: false, detail: "stream timeout"))
                chat.reloadChat()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    runScenarios(scenarios, index: index + 1, chat: chat, issues: nextIssues, toolResults: nextTools, completion: completion)
                }
            } else {
                let finalize = {
                    nextIssues.append(contentsOf: verifyScenario(step, chat: chat))
                    let stepIssues = nextIssues.filter { $0.caseID == step.id && isFunctionalIssue($0) }
                    nextTools.append(ToolResult(
                        id: step.id,
                        ok: stepIssues.isEmpty,
                        detail: stepIssues.first?.detail ?? "ok"
                    ))
                    chat.reloadChat()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        runScenarios(scenarios, index: index + 1, chat: chat, issues: nextIssues, toolResults: nextTools, completion: completion)
                    }
                }
                if step.requireUserImage {
                    waitForImagePipeline(chat: chat, timeout: 90, completion: finalize)
                } else {
                    finalize()
                }
            }
        }
    }

    private static func runStudyCaptureScenario(
        id: String,
        pdfPath: String,
        prompt: String,
        chat: ChatViewController,
        issues: [RenderAuditChecks.Issue],
        toolResults: [ToolResult],
        completion: @escaping ([RenderAuditChecks.Issue], [ToolResult]) -> Void
    ) {
        let path = NSString(string: pdfPath).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: path) else {
            var nextIssues = issues
            var nextTools = toolResults
            nextIssues.append(RenderAuditChecks.Issue(caseID: id, kind: "pdf-missing", detail: path))
            nextTools.append(ToolResult(id: id, ok: false, detail: "pdf missing"))
            completion(nextIssues, nextTools)
            return
        }
        do {
            let doc = try StudyDocumentStore.shared.importPDF(from: url, title: name)
            chat.debugAttachStudyDocument(documentID: doc.id)
            print("\(logTag) study attach \(name) pages=\(StudyDocumentStore.shared.cachedPDFDocument(for: doc.id)?.pageCount ?? 0)")
            let shell = chat.studyContextProvider as? StudyShellViewController
            shell?.debugWaitForStudyCaptureReady(documentID: doc.id, timeout: 90) { ready in
                var nextIssues = issues
                var nextTools = toolResults
                guard ready else {
                    nextIssues.append(RenderAuditChecks.Issue(caseID: id, kind: "study-capture", detail: "PDF not ready for capture"))
                    nextTools.append(ToolResult(id: id, ok: false, detail: "capture not ready"))
                    completion(nextIssues, nextTools)
                    return
                }
                shell?.debugExpandChatPanel()
                applyToolToggles(Scenario(id: id, prompt: prompt, thinking: false, webSearch: false))
                print("\(logTag) send study-capture: \(id)")
                chat.debugSendUserMessage(
                    prompt,
                    studyCaptureEnabled: true,
                    timeout: 300
                ) { ok in
                    waitForImagePipeline(chat: chat, timeout: 45) {
                        var stepIssues: [RenderAuditChecks.Issue] = []
                        if !ok {
                            stepIssues.append(RenderAuditChecks.Issue(caseID: id, kind: "stream", detail: "timeout or failed"))
                        } else if let user = ConversationStore.shared.currentConversation?.messages.last(where: { $0.role == .user }) {
                            let assistant = ConversationStore.shared.currentConversation?.messages.last(where: { $0.role == .assistant })
                            if let err = verifyStudyUserMessage(user, assistant: assistant) {
                                stepIssues.append(RenderAuditChecks.Issue(caseID: id, kind: "study-capture", detail: err))
                            }
                        }
                        nextIssues.append(contentsOf: stepIssues)
                    nextTools.append(ToolResult(
                        id: id,
                        ok: stepIssues.isEmpty,
                        detail: stepIssues.first?.detail ?? "ok"
                    ))
                    chat.debugSetStudyCaptureEnabled(false)
                    chat.reloadChat()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        completion(nextIssues, nextTools)
                    }
                    }
                }
            }
        } catch {
            var nextIssues = issues
            var nextTools = toolResults
            nextIssues.append(RenderAuditChecks.Issue(caseID: id, kind: "pdf-import", detail: error.localizedDescription))
            nextTools.append(ToolResult(id: id, ok: false, detail: error.localizedDescription))
            completion(nextIssues, nextTools)
        }
    }

    private static let renderIssueKinds: Set<String> = [
        "preview-clipped", "formula", "layout-height", "parse", "empty-response"
    ]

    private static func isFunctionalIssue(_ issue: RenderAuditChecks.Issue) -> Bool {
        !renderIssueKinds.contains(issue.kind) && !issue.caseID.hasPrefix("font-")
    }

    private static func applyToolToggles(_ step: Scenario) {
        if let thinking = step.thinking {
            SettingsManager.shared.thinkingEnabled = thinking
        }
        if let search = step.webSearch {
            SettingsManager.shared.webSearchEnabled = search
        }
    }

    private static func verifyScenario(_ step: Scenario, chat: ChatViewController) -> [RenderAuditChecks.Issue] {
        guard let conv = ConversationStore.shared.currentConversation else {
            return [RenderAuditChecks.Issue(caseID: step.id, kind: "state", detail: "no conversation")]
        }
        var issues: [RenderAuditChecks.Issue] = []
        guard let assistant = conv.messages.last(where: { $0.role == .assistant }) else {
            issues.append(RenderAuditChecks.Issue(caseID: step.id, kind: "reply", detail: "no assistant message"))
            return issues
        }
        if step.requireUserImage {
            if let user = conv.messages.last(where: { $0.role == .user }),
               let err = verifyUploadedImage(user, assistant: assistant) {
                issues.append(RenderAuditChecks.Issue(caseID: step.id, kind: "image", detail: err))
            }
        }
        if step.requireReasoning {
            let think = assistant.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if think.isEmpty {
                issues.append(RenderAuditChecks.Issue(caseID: step.id, kind: "thinking", detail: "reasoning content empty"))
            } else {
                print("\(logTag) thinking OK \(step.id) chars=\(think.count)")
            }
        }
        if step.requireSearch {
            let hadSearch = assistant.hasSearchProcess || assistant.searchProcessPhase != .idle
            if !hadSearch {
                issues.append(RenderAuditChecks.Issue(caseID: step.id, kind: "web-search", detail: "no search process recorded"))
            } else {
                print("\(logTag) search OK \(step.id)")
            }
        }
        if !assistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if step.id == "plain-chat-tex" {
                issues.append(contentsOf: RenderAuditChecks.auditAssistantContent(assistant.content, caseID: step.id))
            }
        } else if !step.requireReasoning {
            issues.append(RenderAuditChecks.Issue(caseID: step.id, kind: "reply", detail: "assistant content empty"))
        }
        if issues.filter({ $0.caseID == step.id }).isEmpty {
            print("\(logTag) tool OK \(step.id)")
        }
        return issues
    }

    private static func verifyUploadedImage(_ user: ChatMessage, assistant: ChatMessage) -> String? {
        if user.hasImage { return nil }
        if let description = user.imageDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            return nil
        }
        let transcription = assistant.imageTranscriptionContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if assistant.imageTranscriptionPhase == .done, !transcription.isEmpty {
            return nil
        }
        return "image pipeline produced no durable description"
    }

    private static func verifyStudyUserMessage(_ user: ChatMessage, assistant: ChatMessage? = nil) -> String? {
        if user.hidesAttachedImageInChat {
            guard user.hasImage else { return "PDF study capture missing JPEG for 图片转写" }
            guard !user.showsImageInChat else { return "PDF screenshot should stay out of chat bubble" }
            if let assistant = assistant {
                if assistant.hasImageTranscription { return nil }
                if assistant.imageTranscriptionPhase == .transcribing { return nil }
                return "PDF study capture missing 图片转写 tag"
            }
            if user.apiContextPrefix?.contains("[阅读上下文") == true { return nil }
            return "PDF study capture missing assistant transcription"
        }
        if user.hasImage { return nil }
        if let description = user.imageDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            return nil
        }
        if user.apiContextPrefix?.contains("[阅读上下文") == true { return nil }
        if user.content.contains("页") && user.content.contains("/") { return nil }
        if let assistant = assistant {
            let transcription = assistant.imageTranscriptionContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if assistant.imageTranscriptionPhase == .done, !transcription.isEmpty {
                return nil
            }
        }
        return "study page screenshot/context not recorded"
    }

    private static func waitForImagePipeline(chat: ChatViewController, timeout: TimeInterval, completion: @escaping () -> Void) {
        guard let convID = ConversationStore.shared.currentConversationID else {
            completion()
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if Date() > deadline {
                completion()
                return
            }
            if let conv = ConversationStore.shared.currentConversation,
               let user = conv.messages.last(where: { $0.role == .user }),
               let assistant = conv.messages.last(where: { $0.role == .assistant }) {
                if verifyStudyUserMessage(user) == nil || verifyUploadedImage(user, assistant: assistant) == nil {
                    completion()
                    return
                }
            }
            if !ImageTranscriptionCoordinator.shared.isTranscribing(convID) {
                completion()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
        }
        poll()
    }

    private static func makeTestImageBase64(label: String) -> String? {
        let size = CGSize(width: 360, height: 140)
        UIGraphicsBeginImageContextWithOptions(size, true, 2)
        defer { UIGraphicsEndImageContext() }
        UIColor.white.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 32, weight: .semibold),
            .foregroundColor: UIColor.black
        ]
        (label as NSString).draw(at: CGPoint(x: 20, y: 48), withAttributes: attrs)
        guard let image = UIGraphicsGetImageFromCurrentImageContext() else { return nil }
        return ImageAttachmentHelper.prepareJPEGBase64(from: image)
    }

    private static func auditFontSizes() -> [RenderAuditChecks.Issue] {
        var issues: [RenderAuditChecks.Issue] = []
        let original = SettingsManager.shared.chatFontSizeIndex
        guard let content = ConversationStore.shared.currentConversation?.messages.first(where: {
            $0.role == .assistant && !$0.content.isEmpty
        })?.content else {
            return issues
        }
        for index in 0...2 {
            SettingsManager.shared.chatFontSizeIndex = index
            issues.append(contentsOf: RenderAuditChecks.auditAssistantContent(content, caseID: "font-\(index)"))
        }
        SettingsManager.shared.chatFontSizeIndex = original
        return issues
    }

    private static func runScrollCheck(
        on chat: ChatViewController,
        completion: @escaping ([RenderAuditChecks.Issue]) -> Void
    ) {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              messages.count >= 4 else {
            completion([])
            return
        }
        chat.ensureBottomPinnedIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            var issues: [RenderAuditChecks.Issue] = []
            let anchorRow = max(0, messages.count - 5)
            var step = 0
            let total = 8
            let scrollDistance: CGFloat = 180

            func next() {
                guard step < total else {
                    completion(issues)
                    return
                }
                guard let beforeY = chat.debugRowViewportY(row: anchorRow) else {
                    step += 1
                    next()
                    return
                }
                chat.debugSimulateScrollUp(distance: scrollDistance) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if let afterY = chat.debugRowViewportY(row: anchorRow) {
                            let expected = beforeY + scrollDistance
                            let drift = abs(afterY - expected)
                            if drift > 56 {
                                issues.append(RenderAuditChecks.Issue(
                                    caseID: "scroll-\(step)",
                                    kind: "viewport-drift",
                                    detail: "row=\(anchorRow) drift=\(Int(drift))pt"
                                ))
                                print("\(logTag) scroll drift step=\(step) row=\(anchorRow) drift=\(Int(drift))pt")
                            }
                        }
                        step += 1
                        next()
                    }
                }
            }
            next()
        }
    }

    private static func report(issues: [RenderAuditChecks.Issue], tools: [ToolResult]) {
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("connects-usage-sim-report.json")
        let payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "toolPassCount": tools.filter(\.ok).count,
            "toolFailCount": tools.filter { !$0.ok }.count,
            "renderIssueCount": issues.count,
            "tools": tools.map { ["id": $0.id, "ok": $0.ok, "detail": $0.detail] as [String: Any] },
            "issues": issues.map { ["caseID": $0.caseID, "kind": $0.kind, "detail": $0.detail] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: url)
            print("\(logTag) report → \(url.path)")
        }
        for tool in tools {
            print("\(logTag) tool \(tool.id): \(tool.ok ? "OK" : "FAIL") \(tool.detail)")
        }
        if issues.isEmpty {
            print("\(logTag) PASS (tools + render)")
        } else if tools.allSatisfy(\.ok) {
            print("\(logTag) PASS tools, \(issues.count) render warning(s)")
        } else {
            print("\(logTag) FAIL \(tools.filter { !$0.ok }.count) tool(s), \(issues.count) issue(s)")
        }
    }

    private static func finish(exitCode: Int32) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            exit(exitCode)
        }
    }
}
#endif
