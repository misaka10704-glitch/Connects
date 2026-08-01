import Foundation

/// Workspace-only agent loop: parse CONNECTS_TOOL blocks, run local tools, re-ask model.
final class AgentOrchestrator {
    static let shared = AgentOrchestrator()

    /// Soft safety — stop pathological tool spam. Normal turns finish when the model
    /// emits no more CONNECTS_TOOL blocks (or Plan writes its md).
    static let maxRounds = 24
    private var pendingAsk: (conversationID: String, prompt: String)?
    /// Model for nested `spawn_subagent` LLM mini-loops (set by ChatViewController per turn).
    var subagentModel: AIModelOption?
    /// One nudge per assistant shell when the model claims edits without tool blocks.
    private var nudgedMissingTools: Set<String> = []
    /// OpenCode-style doom-loop fingerprints for the active agent turn (per conversation).
    private var turnFingerprints: [String: Set<String>] = [:]
    private var lastPlanFingerprint: [String: String] = [:]
    /// True once list_dir/glob succeeded this turn (ritual gate).
    private var listedWorkspaceThisTurn: [String: Bool] = [:]
    /// True once update_plan was accepted this turn.
    private var acceptedPlanThisTurn: [String: Bool] = [:]
    /// True once create/edit/delete succeeded this turn.
    private var mutatedThisTurn: [String: Bool] = [:]

    private init() {}

    var waitingAskPrompt: String? { pendingAsk?.prompt }

    func clearPendingAsk(for conversationID: String? = nil) {
        if let conversationID, pendingAsk?.conversationID != conversationID { return }
        pendingAsk = nil
    }

    func resetTurnDedup(for conversationID: String) {
        turnFingerprints[conversationID] = []
        lastPlanFingerprint[conversationID] = nil
        listedWorkspaceThisTurn[conversationID] = false
        acceptedPlanThisTurn[conversationID] = false
        mutatedThisTurn[conversationID] = false
    }

    func endTurnDedup(for conversationID: String) {
        turnFingerprints.removeValue(forKey: conversationID)
        lastPlanFingerprint.removeValue(forKey: conversationID)
        listedWorkspaceThisTurn.removeValue(forKey: conversationID)
        acceptedPlanThisTurn.removeValue(forKey: conversationID)
        mutatedThisTurn.removeValue(forKey: conversationID)
        nudgedMissingTools = nudgedMissingTools.filter { !$0.hasPrefix("\(conversationID):") }
    }

    func currentRoundCapReached(count: Int) -> Bool { count >= Self.maxRounds }

    private static func looksLikeClaimedWorkspaceEdit(_ content: String) -> Bool {
        let lower = content.lowercased()
        let markers = [
            "create_file", "spawn_subagent", "propose_edit",
            "已创建", "创建完成", "任务完成", "spi_master", "spi_slave",
            "async_fifo", "uart", ".sv", ".vhd", "module "
        ]
        return markers.contains { lower.contains($0.lowercased()) }
            || content.contains("- [x]")
    }

    /// Stable fingerprint for duplicate / doom-loop detection (OpenCode-inspired).
    private static func fingerprint(for call: AgentToolCall) -> String {
        switch call.name {
        case .listDir:
            return "list_dir"
        case .readFile:
            let path = (call.arguments["path"] ?? "").lowercased()
            return "read:\(path)"
        case .grep:
            let q = (call.arguments["query"] ?? "").lowercased()
            return "grep:\(q)"
        case .glob:
            let p = (call.arguments["pattern"] ?? call.arguments["path"] ?? "*").lowercased()
            return "glob:\(p)"
        case .updatePlan:
            let plan = (call.arguments["plan"] ?? call.arguments["body"] ?? "")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return "update_plan:\(plan.prefix(2_000))"
        case .spawnSubagent:
            let role = (call.arguments["role"] ?? "explore").lowercased()
            let task = (call.arguments["task"] ?? call.arguments["prompt"] ?? "")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .lowercased()
            return "spawn:\(role):\(task.prefix(120))"
        case .proposeEdit, .createFile, .deleteFile:
            let path = (call.arguments["path"] ?? "").lowercased()
            return "\(call.name.rawValue):\(path)"
        case .askUser:
            return "ask_user"
        }
    }

    /// System / prefix injected for workspace agent turns.
    func apiPrefix(for conversation: Conversation, workspaceListing: String) -> String {
        var parts: [String] = [AgentTools.authorizationPrefix]
        parts.append("## WORKSPACE FILES\n\(workspaceListing)")
        if let active = conversation.studyActiveFileName {
            parts.append("""
            ## ACTIVE FILE (only writable target)
            \(active)
            propose_edit / delete_file ONLY for this file. Read/list/grep/glob may use the whole folder.
            create_file is blocked in Agent mode (use UI +). To edit another file, the user must switch the reader first — do not write other paths.
            """)
        } else {
            parts.append("""
            ## ACTIVE FILE
            (none open) — do not propose_edit / delete_file / create_file until the user opens a file.
            """)
        }
        parts.append("Mode: \(conversation.studyAgentMode.rawValue)")
        if let ask = pendingAsk, ask.conversationID == conversation.id {
            parts.append("User answered your question. Continue.")
        }
        return parts.joined(separator: "\n\n")
    }

    /// After an assistant finish in workspace mode — run tool loop if needed.
    @discardableResult
    func handleAssistantFinished(
        conversationID: String,
        assistantMessageID: String,
        content: String,
        workspaceID: String,
        mode: StudyAgentMode,
        model: AIModelOption? = nil,
        appendStep: @escaping (AgentProcessStep) -> Void,
        updateStep: @escaping (AgentProcessStep) -> Void,
        onProposeEdit: @escaping (String, String) -> Void,
        onPlanUpdate: ((String) -> Void)? = nil,
        requestContinuation: @escaping (_ toolResults: String) -> Void
    ) -> Bool {
        subagentModel = model
        defer { subagentModel = nil }

        if turnFingerprints[conversationID] == nil {
            turnFingerprints[conversationID] = []
            listedWorkspaceThisTurn[conversationID] = false
            acceptedPlanThisTurn[conversationID] = false
            mutatedThisTurn[conversationID] = false
        }

        let calls = AgentTools.parseToolCalls(from: content)
        guard !calls.isEmpty else {
            // Model often narrates "created foo.v" in markdown without real tool blocks.
            if mode == .agent, Self.looksLikeClaimedWorkspaceEdit(content) {
                let key = "\(conversationID):\(assistantMessageID)"
                if !nudgedMissingTools.contains(key) {
                    nudgedMissingTools.insert(key)
                    requestContinuation("""
                    ## TOOL_RESULTS
                    error: no <<<CONNECTS_TOOL blocks were parsed. Markdown/plan text does not create files.
                    Immediately emit a real tool block:
                    <<<CONNECTS_TOOL
                    name: create_file
                    path: spi_master.sv
                    ```
                    (module body)
                    ```
                    CONNECTS_TOOL>>>
                    Or spawn_subagent role=edit with task describing the file to create. No prose-only claims.
                    """)
                    return true
                }
            }
            pendingAsk = nil
            endTurnDedup(for: conversationID)
            return false
        }

        var resultChunks: [String] = []
        var needAsk: String?
        var skippedDupes = 0
        var didMutatingWork = false

        for call in calls {
            let fp = Self.fingerprint(for: call)
            var seen = turnFingerprints[conversationID] ?? []

            // Ritual gate: after list/glob with no mutate, block explore subagent / 2nd plan.
            let listed = listedWorkspaceThisTurn[conversationID] == true
            let mutated = mutatedThisTurn[conversationID] == true || didMutatingWork
            let plannedOnce = acceptedPlanThisTurn[conversationID] == true
            if listed, !mutated {
                if call.name == .spawnSubagent {
                    let role = (call.arguments["role"] ?? "explore").lowercased()
                    if role != "edit" {
                        skippedDupes += 1
                        resultChunks.append(
                            "[spawn_subagent] skipped ritual explore — workspace already listed. Use create_file / propose_edit / delete_file or finish with a short answer."
                        )
                        continue
                    }
                }
                if call.name == .updatePlan, plannedOnce {
                    skippedDupes += 1
                    resultChunks.append(
                        "[update_plan] skipped — already planned this turn after list_dir. Edit or finish; do not re-plan."
                    )
                    continue
                }
            }

            // Duplicate read / list / grep / plan → skip (no chrome spam).
            // delete/create/propose are NOT idempotent here — retries after failure must run.
            let isIdempotentExplore =
                call.name == .readFile
                || call.name == .listDir
                || call.name == .grep
                || call.name == .glob
                || call.name == .updatePlan

            if isIdempotentExplore, seen.contains(fp) {
                skippedDupes += 1
                resultChunks.append(
                    "[\(call.name.rawValue)] skipped duplicate — already done this turn. Do not repeat; finish or edit."
                )
                continue
            }

            // update_plan with same normalized body as last accepted plan.
            if call.name == .updatePlan {
                let planBody = (call.arguments["plan"] ?? call.arguments["body"] ?? "")
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let last = lastPlanFingerprint[conversationID], last == fp {
                    skippedDupes += 1
                    resultChunks.append("[update_plan] skipped — plan unchanged. Do not call update_plan again.")
                    continue
                }
                if planBody.count < 8 {
                    skippedDupes += 1
                    resultChunks.append("[update_plan] skipped — empty/trivial plan.")
                    continue
                }
            }

            // Fingerprint only after success — failed tools must be retryable.
            let meta = AgentTools.humanStepTitle(for: call)
            var step = AgentProcessStep(
                kind: meta.kind,
                title: meta.title,
                detail: "",
                status: .running
            )
            appendStep(step)
            let activeFile = ConversationStore.shared.conversation(id: conversationID)?.studyActiveFileName
            let result = AgentTools.execute(
                call,
                workspaceID: workspaceID,
                mode: mode,
                activeFileName: activeFile
            )
            let succeeded: Bool = {
                switch result {
                case .text(let t): return !t.lowercased().hasPrefix("error:")
                case .askUser, .proposeEdit, .plan, .subagentSummary: return true
                }
            }()
            if succeeded {
                seen.insert(fp)
                turnFingerprints[conversationID] = seen
            }

            switch result {
            case .text(let t):
                step.markDone()
                step.detail = AgentTools.humanStepDetailSummary(for: call, result: result)
                if call.name == .deleteFile, !t.lowercased().hasPrefix("error:") {
                    if !step.detail.isEmpty { step.title = step.detail }
                    didMutatingWork = true
                    mutatedThisTurn[conversationID] = true
                }
                if (call.name == .listDir || call.name == .glob), !t.lowercased().hasPrefix("error:") {
                    listedWorkspaceThisTurn[conversationID] = true
                }
                updateStep(step)
                resultChunks.append("[\(call.name.rawValue)]\n\(t)")
            case .askUser(let prompt):
                step.markDone()
                step.detail = AgentTools.humanStepDetailSummary(for: call, result: result)
                updateStep(step)
                needAsk = prompt
                pendingAsk = (conversationID, prompt)
            case .proposeEdit(let path, let body):
                step.markDone()
                step.detail = AgentTools.humanStepDetailSummary(for: call, result: result)
                if !step.detail.isEmpty { step.title = step.detail }
                updateStep(step)
                onProposeEdit(path, body)
                didMutatingWork = true
                mutatedThisTurn[conversationID] = true
                resultChunks.append("[\(call.name.rawValue)] queued edit for \(path) (\(body.count) chars)")
            case .plan(let p):
                step.markDone()
                step.detail = AgentTools.humanStepDetailSummary(for: call, result: result)
                updateStep(step)
                lastPlanFingerprint[conversationID] = fp
                acceptedPlanThisTurn[conversationID] = true
                if mode == .plan || mode == .agent {
                    onPlanUpdate?(p)
                }
                resultChunks.append("[update_plan]\n\(p)")
            case .subagentSummary(let s):
                step.markDone()
                step.detail = AgentTools.humanStepDetailSummary(for: call, result: result)
                if call.name == .spawnSubagent {
                    let role = (call.arguments["role"] ?? "explore")
                    step.title = role.lowercased() == "edit" ? "Edit subagent" : "Explore subagent"
                    let task = call.arguments["task"] ?? ""
                    if !task.isEmpty {
                        step.detail = String(task.prefix(80))
                    }
                }
                updateStep(step)
                resultChunks.append("[spawn_subagent]\n\(s)")
                let edits = AgentSubagentRunner.takePendingEdits()
                if !edits.isEmpty {
                    didMutatingWork = true
                    mutatedThisTurn[conversationID] = true
                }
                for edit in edits {
                    onProposeEdit(edit.path, edit.content)
                }
            }
        }

        if needAsk != nil {
            NotificationCenter.default.post(name: .agentProcessDidUpdate, object: conversationID)
            return false
        }

        if mode == .plan {
            let wrotePlan = calls.contains { $0.name == .updatePlan || $0.name == .createFile }
            if wrotePlan {
                pendingAsk = nil
                endTurnDedup(for: conversationID)
                NotificationCenter.default.post(name: .agentProcessDidUpdate, object: conversationID)
                return false
            }
        }

        let joined = resultChunks.joined(separator: "\n\n")
        if joined.isEmpty { return false }

        // If we only skipped duplicates / ritual and did no new work, nudge once to edit —
        // do NOT end the turn (that left the agent unable to mutate after list_dir).
        if skippedDupes > 0, !didMutatingWork,
           calls.allSatisfy({
               $0.name == .readFile || $0.name == .listDir || $0.name == .grep
                   || $0.name == .glob || $0.name == .updatePlan || $0.name == .spawnSubagent
           }),
           (turnFingerprints[conversationID] ?? []).count >= 1 {
            let onlyDupes = resultChunks.allSatisfy { $0.contains("skipped") }
            if onlyDupes {
                requestContinuation("""
                ## TOOL_RESULTS
                \(joined)

                All prior explore/plan calls were skipped. Immediately emit create_file / propose_edit / delete_file (or spawn_subagent role=edit). Do not list/explore/plan again. If nothing to change, reply with a short final answer and NO tools.
                """)
                return true
            }
        }

        let nudge: String
        if didMutatingWork || mutatedThisTurn[conversationID] == true {
            nudge = """
            Continue. If more file work remains, emit propose_edit / create_file / delete_file.
            Otherwise reply with a short final answer and NO tool blocks.
            Do not ritual list→explore→plan. Never clear a file to fake a delete.
            """
        } else {
            nudge = """
            Continue. Prefer create_file / propose_edit / delete_file (or one spawn_subagent role=edit).
            Do not ritual list→explore→plan again. If done, answer briefly with no tools.
            Never say you cannot delete; never empty a file instead of delete_file.
            """
        }
        requestContinuation("""
        ## TOOL_RESULTS
        \(joined)

        \(nudge)
        """)
        return true
    }
}
