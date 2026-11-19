import Foundation

/// Bounded explore/edit mini-loop for `spawn_subagent` (serial, Cursor-style dispatch).
enum AgentSubagentRunner {
    enum Role: String {
        case explore
        case edit
    }

    static let maxRounds = 5

    /// Run a scoped subagent. Uses non-streaming `APIClient.complete` when a model is provided;
    /// otherwise falls back to a local explore glance so the tool never no-ops.
    static func run(
        role: Role,
        task: String,
        paths: [String],
        workspaceID: String,
        mode: StudyAgentMode,
        model: AIModelOption?,
        onStep: ((AgentProcessStep) -> Void)? = nil
    ) -> String {
        switch role {
        case .explore:
            return runExplore(
                task: task,
                paths: paths,
                workspaceID: workspaceID,
                mode: mode,
                model: model,
                onStep: onStep
            )
        case .edit:
            return runEdit(
                task: task,
                paths: paths,
                workspaceID: workspaceID,
                mode: mode,
                model: model,
                onStep: onStep
            )
        }
    }

    // MARK: - Explore

    private static func runExplore(
        task: String,
        paths: [String],
        workspaceID: String,
        mode: StudyAgentMode,
        model: AIModelOption?,
        onStep: ((AgentProcessStep) -> Void)?
    ) -> String {
        var notes: [String] = []
        let listing = AgentTools.execute(
            AgentToolCall(name: .listDir, arguments: [:]),
            workspaceID: workspaceID,
            mode: mode
        )
        if case .text(let t) = listing {
            notes.append("[list_dir]\n\(t)")
        }

        if let model {
            let system = """
            ## CONNECTS_EXPLORE_SUBAGENT
            You only explore. Tools: list_dir, glob, grep, read_file.
            Do NOT propose_edit or create_file. Max \(maxRounds) tool rounds.
            Task: \(task)
            Prefer targeted grep/read. Never re-read the same path.
            Emit CONNECTS_TOOL blocks; when done, one short summary with no tools.
            """
            notes.append(contentsOf: runLLMToolLoop(
                system: system,
                task: task,
                workspaceID: workspaceID,
                mode: mode,
                model: model,
                allowed: [.listDir, .glob, .grep, .readFile],
                onStep: onStep
            ))
        } else {
            // Offline glance: read up to 2 named paths.
            for path in paths.prefix(2) {
                let r = AgentTools.execute(
                    AgentToolCall(name: .readFile, arguments: ["path": path]),
                    workspaceID: workspaceID,
                    mode: mode
                )
                if case .text(let t) = r {
                    notes.append("[read_file \(path)]\n\(String(t.prefix(1200)))")
                }
            }
        }
        return "## SUBAGENT explore\nTask: \(task)\n\n" + notes.joined(separator: "\n\n")
    }

    // MARK: - Edit

    private static func runEdit(
        task: String,
        paths: [String],
        workspaceID: String,
        mode: StudyAgentMode,
        model: AIModelOption?,
        onStep: ((AgentProcessStep) -> Void)?
    ) -> String {
        guard mode == .agent else {
            return "## SUBAGENT edit\nerror: edit subagent requires Agent mode"
        }
        guard let model else {
            return """
            ## SUBAGENT edit
            Task: \(task)
            Paths: \(paths.joined(separator: ", "))
            (no model) Root agent should create_file / propose_edit with old_string/new_string patches.
            """
        }
        let pathHint = paths.isEmpty ? "infer from task" : paths.joined(separator: ", ")
        let system = """
        ## CONNECTS_EDIT_SUBAGENT
        You edit files inside the workspace folder. Tools: read_file, propose_edit.
        You may propose_edit ANY file listed in the workspace (prefer the task's named paths); use relative paths for subfolders.
        Existing files: propose_edit with unique old_string + new_string only (no full-file rewrite).
        Task: \(task)
        Preferred paths: \(pathHint)
        Max \(maxRounds) rounds. Emit CONNECTS_TOOL blocks; finish with a one-line summary naming files written.
        """
        let notes = runLLMToolLoop(
            system: system,
            task: task,
            workspaceID: workspaceID,
            mode: mode,
            model: model,
            allowed: [.readFile, .proposeEdit],
            onStep: onStep,
            proposeSink: true
        )
        let listing = AgentTools.execute(
            AgentToolCall(name: .listDir, arguments: [:]),
            workspaceID: workspaceID,
            mode: mode
        )
        var footer = ""
        if case .text(let t) = listing {
            footer = "\n\n[workspace_after]\n\(t)"
        }
        return "## SUBAGENT edit\nTask: \(task)\n\n" + notes.joined(separator: "\n\n") + footer
    }

    // MARK: - LLM tool loop

    private static func runLLMToolLoop(
        system: String,
        task: String,
        workspaceID: String,
        mode: StudyAgentMode,
        model: AIModelOption,
        allowed: Set<AgentToolName>,
        onStep: ((AgentProcessStep) -> Void)?,
        proposeSink: Bool = false
    ) -> [String] {
        var notes: [String] = []
        var history: [ChatMessage] = [
            ChatMessage(role: .system, content: system),
            ChatMessage(role: .user, content: task)
        ]
        var readOnce = Set<String>()
        var pendingEdits: [(path: String, content: String, createdFresh: Bool)] = []

        for _ in 0..<maxRounds {
            let reply = completeSync(messages: history, model: model, maxTokens: 2048)
            guard let reply, !reply.isEmpty else { break }
            let calls = AgentTools.parseToolCalls(from: reply).filter { allowed.contains($0.name) }
            if calls.isEmpty {
                let prose = AgentTools.strippingToolBlocksForDisplay(from: reply)
                if !prose.isEmpty { notes.append("[summary]\n\(prose)") }
                break
            }
            var chunk: [String] = []
            for call in calls {
                if call.name == .readFile, let path = call.arguments["path"] {
                    let key = path.lowercased()
                    if readOnce.contains(key) {
                        chunk.append("[\(call.name.rawValue)] skipped duplicate read \(path)")
                        continue
                    }
                    readOnce.insert(key)
                }
                let meta = AgentTools.humanStepTitle(for: call)
                var step = AgentProcessStep(
                    kind: meta.kind,
                    title: meta.title,
                    detail: "",
                    status: .running
                )
                onStep?(step)
                let result = AgentTools.execute(
                    call,
                    workspaceID: workspaceID,
                    mode: mode,
                    activeFileName: ConversationStore.shared.currentConversation?.studyActiveFileName
                )
                switch result {
                case .text(let t):
                    step.markDone()
                    step.detail = AgentTools.humanStepDetailSummary(for: call, result: result)
                    onStep?(step)
                    chunk.append("[\(call.name.rawValue)]\n\(String(t.prefix(4000)))")
                case .proposeEdit(let path, let content, let fresh):
                    step.markDone()
                    step.detail = AgentTools.humanStepDetailSummary(for: call, result: result)
                    onStep?(step)
                    if proposeSink {
                        pendingEdits.append((path, content, fresh))
                    }
                    chunk.append("[propose_edit] \(path) (\(content.count) chars) queued")
                case .askUser(let p):
                    step.markDone()
                    onStep?(step)
                    chunk.append("[ask_user] \(p)")
                case .plan(let p):
                    step.markDone()
                    onStep?(step)
                    chunk.append("[plan]\n\(p)")
                case .subagentSummary(let s):
                    step.markDone()
                    onStep?(step)
                    chunk.append(s)
                }
            }
            let joined = chunk.joined(separator: "\n\n")
            notes.append(joined)
            history.append(ChatMessage(role: .assistant, content: reply))
            history.append(ChatMessage(
                role: .user,
                content: "## TOOL_RESULTS\n\(joined)\n\nContinue or finish with a short summary."
            ))
        }

        // Apply queued edits after the loop (caller ChatVC also handles root propose_edit).
        for edit in pendingEdits {
            notes.append("[edit_applied_pending] \(edit.path) \(edit.content.count)B — root will persist via session")
            // Persist via notification-style side channel: store for orchestrator callback.
            AgentSubagentRunner.drainPendingEdits.append(edit)
        }
        return notes
    }

    /// Edits produced by edit subagent awaiting disk write by ChatViewController.
    static var drainPendingEdits: [(path: String, content: String, createdFresh: Bool)] = []

    static func takePendingEdits() -> [(path: String, content: String, createdFresh: Bool)] {
        let out = drainPendingEdits
        drainPendingEdits = []
        return out
    }

    private static func completeSync(messages: [ChatMessage],
                                     model: AIModelOption,
                                     maxTokens: Int) -> String? {
        // Must not hop to main then wait — call from background tool queue.
        // Use blocking complete so URLSession callback can signal without main deadlock risk.
        let sem = DispatchSemaphore(value: 0)
        var out: String?
        let client = APIClient()
        client.completeBlocking(messages: messages, model: model, maxTokens: maxTokens, timeout: 90) { result in
            if case .success(let s) = result { out = s }
            sem.signal()
        }
        let waited = sem.wait(timeout: .now() + 95)
        if waited == .timedOut { return nil }
        return out
    }
}
