import Foundation

enum AgentToolName: String {
    case listDir = "list_dir"
    case readFile = "read_file"
    case grep = "grep"
    case glob = "glob"
    case proposeEdit = "propose_edit"
    case createFile = "create_file"
    case deleteFile = "delete_file"
    case askUser = "ask_user"
    case updatePlan = "update_plan"
    case spawnSubagent = "spawn_subagent"
}

struct AgentToolCall {
    let name: AgentToolName
    let arguments: [String: String]
}

enum AgentToolResult {
    case text(String)
    case askUser(prompt: String)
    case proposeEdit(path: String, content: String)
    case plan(String)
    case subagentSummary(String)
}

/// Local tools scoped to a Study workspace folder.
enum AgentTools {
    static let authorizationPrefix: String = """
    ## CONNECTS_WORKSPACE_AGENT
    You are the ROOT planner in a real folder workspace. Prefer the smallest tool set that finishes the user request.

    Anti-loop (OpenCode-style — CRITICAL):
    - Call update_plan AT MOST once at the start (or when todos truly change). Never spam Updated plan.
    - list_dir / glob at most once unless TOOL_RESULTS show the folder changed.
    - After list_dir/glob: do NOT spawn_subagent role=explore and do NOT call update_plan again — edit/delete or finish.
    - Never read_file the same path twice in one turn. Use prior TOOL_RESULTS.
    - Small cleanup: list_dir once → delete_file ×N → short final answer. No ritual plan→explore→read loops.
    - When TOOL_RESULTS already satisfy the ask (esp. after successful mutate), either more propose_edit/delete_file or a short final answer.
    - User-visible final prose: one short paragraph after tools finish — avoid long answers between tool rounds.

    Rhythm (Agent mode, only if needed):
    1) One short intent sentence.
    2) Optional single update_plan with todos (`- [ ]` / `- [x]`) — CONNECTS_TOOL only.
    3) create_file / propose_edit / delete_file, or one focused spawn_subagent.
    4) Brief final answer ONLY after TOOL_RESULTS confirm success.

    CRITICAL: Markdown that looks like tools is ignored. You MUST emit <<<CONNECTS_TOOL ... CONNECTS_TOOL>>> blocks.
    Never mark a todo [x] or say「已创建」until TOOL_RESULTS show create_file/propose_edit/delete_file success.
    NEVER say you cannot delete files. Use delete_file for removals. Do NOT clear file contents as a substitute for delete.

    Tool block format (exactly):
    <<<CONNECTS_TOOL
    name: list_dir|read_file|grep|glob|propose_edit|create_file|delete_file|ask_user|update_plan|spawn_subagent
    path: relative/or/basename   (when needed)
    query: text                  (grep)
    pattern: glob                (glob)
    prompt: text                 (ask_user)
    plan: markdown               (update_plan)
    role: explore|edit           (spawn_subagent)
    task: text                   (spawn_subagent)
    paths: a.swift,b.v           (optional, spawn_subagent)
    old_string: exact prior text (propose_edit patch — preferred)
    new_string: replacement text (propose_edit patch — preferred)
    ```
    body only for create_file or tiny full-file propose_edit fallback
    ```
    CONNECTS_TOOL>>>

    Rules:
    - Root may list_dir once; then edit/delete. Avoid repeated read_file of the same path.
    - Delete via delete_file (workspace only). Never propose_edit with empty body to "clear" a file you should delete.
    - Edit via propose_edit with old_string/new_string, or spawn_subagent role=edit. Never rewrite whole large files in body.
    - Do not call spawn_subagent in a tight loop without advancing work.
    - Never claim a file exists/deleted until TOOL_RESULTS show success. If create/delete fails, retry once.
    - Modes: Agent=edit/delete ok; Plan=no propose_edit/delete_file; Ask=read-only + ask_user.
    - ACTIVE FILE LOCK: propose_edit / delete_file ONLY for the currently open Study file (see ACTIVE FILE below). list_dir/read/grep/glob may use the whole folder. create_file is blocked in Agent (user creates via UI +); Plan mode may create_file for plan markdown. To edit another file, stop — the user must switch the reader title first.
    After tools run you receive results and continue.
    """

    static func parseToolCalls(from content: String) -> [AgentToolCall] {
        var calls: [AgentToolCall] = []
        var search = content.startIndex..<content.endIndex
        while let begin = content.range(of: "<<<CONNECTS_TOOL", options: [.caseInsensitive], range: search),
              let end = content.range(of: "CONNECTS_TOOL>>>", options: [.caseInsensitive], range: begin.upperBound..<content.endIndex) {
            let body = String(content[begin.upperBound..<end.lowerBound])
            if let call = parseOne(body) {
                calls.append(call)
            }
            search = end.upperBound..<content.endIndex
        }
        return calls
    }

    static func strippingToolBlocks(from content: String) -> String {
        var s = content
        while let begin = s.range(of: "<<<CONNECTS_TOOL", options: [.caseInsensitive]),
              let end = s.range(of: "CONNECTS_TOOL>>>", options: [.caseInsensitive], range: begin.upperBound..<s.endIndex) {
            s.removeSubrange(begin.lowerBound..<end.upperBound)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Chat/stream display: drop complete tool blocks and truncate any open `<<<CONNECTS_TOOL`.
    /// Never leak machine markers (`<<<`, `CONNECTS_TOOL>>>`) into the bubble.
    static func strippingToolBlocksForDisplay(from content: String) -> String {
        var s = strippingToolBlocks(from: content)
        if let open = findOpenConnectsToolBegin(in: s) {
            s = String(s[..<open.lowerBound])
        }
        // Orphan close markers / stray arrows after a partial stream.
        if let orphanClose = s.range(of: "CONNECTS_TOOL>>>", options: [.caseInsensitive]) {
            s.removeSubrange(orphanClose)
        }
        if let arrows = s.range(of: "<<<", options: [.backwards]),
           looksLikeIncompleteConnectsMarkerSuffix(s[arrows.upperBound...]) {
            s = String(s[..<arrows.lowerBound])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True for `<<<` + optional whitespace + empty / any prefix of `connects…`.
    static func looksLikeIncompleteConnectsMarkerSuffix(_ afterArrows: Substring) -> Bool {
        let trimmed = afterArrows.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let lower = trimmed.lowercased()
        let target = "connects"
        // Mid-stream may be `<<<C`, `<<<CONN`, `<<<CONNECTS_TOO`, etc.
        return target.hasPrefix(lower) || lower.hasPrefix(target)
    }

    /// Begin of an unclosed tool block (`<<<CONNECTS_TOOL` or `<<<` + spaces + `CONNECTS_TOOL`).
    static func findOpenConnectsToolBegin(in content: String) -> Range<String.Index>? {
        if let exact = content.range(of: "<<<CONNECTS_TOOL", options: [.caseInsensitive]) {
            let rest = exact.upperBound..<content.endIndex
            if content.range(of: "CONNECTS_TOOL>>>", options: [.caseInsensitive], range: rest) == nil {
                return exact
            }
            return nil
        }
        guard let marker = content.range(of: "CONNECTS_TOOL", options: [.caseInsensitive]) else {
            return nil
        }
        // Avoid matching the close tag CONNECTS_TOOL>>>
        let afterMarker = marker.upperBound..<content.endIndex
        if content[afterMarker].hasPrefix(">>>") { return nil }
        let prefix = content[content.startIndex..<marker.lowerBound]
        guard let arrows = prefix.range(of: "<<<", options: .backwards) else { return nil }
        let between = content[arrows.upperBound..<marker.lowerBound]
        guard between.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }) else {
            return nil
        }
        let begin = arrows.lowerBound..<marker.upperBound
        let rest = marker.upperBound..<content.endIndex
        if content.range(of: "CONNECTS_TOOL>>>", options: [.caseInsensitive], range: rest) != nil {
            return nil
        }
        return begin
    }

    private static func parseOne(_ body: String) -> AgentToolCall? {
        var args: [String: String] = [:]
        var nameRaw = ""
        var inFence = false
        var fenceLines: [String] = []
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence {
                fenceLines.append(line)
                continue
            }
            if trimmed.lowercased().hasPrefix("name:") {
                nameRaw = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let colon = trimmed.firstIndex(of: ":") {
                let key = trimmed[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let val = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                args[key] = val
            }
        }
        if !fenceLines.isEmpty {
            args["body"] = fenceLines.joined(separator: "\n")
        }
        guard let name = AgentToolName(rawValue: nameRaw.lowercased()) else { return nil }
        return AgentToolCall(name: name, arguments: args)
    }

    static func execute(
        _ call: AgentToolCall,
        workspaceID: String,
        mode: StudyAgentMode,
        activeFileName: String? = nil
    ) -> AgentToolResult {
        let active = resolvedActiveFileName(activeFileName)
        switch call.name {
        case .listDir:
            let names = StudyWorkspaceStore.shared.listFileNames(in: workspaceID)
            return .text(names.isEmpty ? "(empty folder)" : names.joined(separator: "\n"))
        case .readFile:
            guard let path = call.arguments["path"], !path.isEmpty else {
                return .text("error: path required")
            }
            return .text(readWorkspaceFile(path, workspaceID: workspaceID))
        case .grep:
            let query = call.arguments["query"] ?? ""
            return .text(grepWorkspace(query: query, workspaceID: workspaceID))
        case .glob:
            let pattern = (call.arguments["pattern"] ?? call.arguments["path"] ?? "*").lowercased()
            let names = StudyWorkspaceStore.shared.listFileNames(in: workspaceID)
            let matched = names.filter { name in
                if pattern == "*" { return true }
                if pattern.hasPrefix("*.") {
                    return name.lowercased().hasSuffix(String(pattern.dropFirst()))
                }
                return name.lowercased().contains(pattern.replacingOccurrences(of: "*", with: ""))
            }
            return .text(matched.isEmpty ? "(no matches)" : matched.joined(separator: "\n"))
        case .proposeEdit:
            if mode == .plan || mode == .ask {
                return .text("error: propose_edit not allowed in \(mode.rawValue) mode")
            }
            let path = call.arguments["path"] ?? ""
            guard !path.isEmpty else { return .text("error: path required") }
            if let denied = mutateScopeError(tool: "propose_edit", path: path, activeFileName: active, mode: mode) {
                return .text(denied)
            }
            let resolvedPath = Self.canonicalizeMutatePath(path, activeFileName: active)
            let oldS = call.arguments["old_string"] ?? call.arguments["old"] ?? ""
            let newS = call.arguments["new_string"] ?? call.arguments["new"] ?? ""
            let body = call.arguments["body"] ?? ""
            let current = readWorkspaceFile(resolvedPath, workspaceID: workspaceID)
            let missing = current.hasPrefix("error:")
            // New file: never queue propose_edit (ChatVC drops unknown paths). Create instead.
            if missing {
                let createBody: String
                if !oldS.isEmpty {
                    createBody = newS
                } else {
                    createBody = body
                }
                guard !createBody.isEmpty else {
                    return .text("error: \(resolvedPath) does not exist — switch to an existing open file, or create via UI (+)")
                }
                return execute(
                    AgentToolCall(name: .createFile, arguments: ["path": resolvedPath, "body": createBody]),
                    workspaceID: workspaceID,
                    mode: mode,
                    activeFileName: active
                )
            }
            if !oldS.isEmpty {
                guard current.contains(oldS) else {
                    return .text("error: old_string not found in \(resolvedPath) — re-read and patch again")
                }
                let occurrences = current.components(separatedBy: oldS).count - 1
                if occurrences != 1 {
                    return .text("error: old_string matched \(occurrences) times in \(resolvedPath); make it unique")
                }
                let patched = current.replacingOccurrences(of: oldS, with: newS, options: [], range: nil)
                return .proposeEdit(path: resolvedPath, content: patched)
            }
            if body.isEmpty {
                return .text("error: propose_edit needs old_string/new_string (preferred) or body")
            }
            // Full-body fallback: reject blind rewrites of large existing files.
            if current.count > 400, body.count > 400 {
                let prefixLen = min(80, current.count, body.count)
                if current.prefix(prefixLen) != body.prefix(prefixLen) {
                    return .text("error: full-body rewrite blocked for \(resolvedPath); use old_string/new_string patch")
                }
            }
            return .proposeEdit(path: resolvedPath, content: body)
        case .createFile:
            if mode == .ask {
                return .text("error: create_file not allowed in ask mode")
            }
            let path = call.arguments["path"] ?? ""
            var body = call.arguments["body"] ?? ""
            guard !path.isEmpty else { return .text("error: path required") }
            if let denied = mutateScopeError(tool: "create_file", path: path, activeFileName: active, mode: mode) {
                return .text(denied)
            }
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedBody.isEmpty {
                return .text("error: create_file body is empty — put the full file contents in the fenced body field")
            }
            // HDL / source stubs that are trivially empty are not useful.
            let lowerPath = path.lowercased()
            if (lowerPath.hasSuffix(".v") || lowerPath.hasSuffix(".sv") || lowerPath.hasSuffix(".vhd")
                || lowerPath.hasSuffix(".swift") || lowerPath.hasSuffix(".c") || lowerPath.hasSuffix(".h")),
               trimmedBody.count < 40 {
                return .text("error: create_file body too short for \(path) (\(trimmedBody.count) chars) — include a real module/source body")
            }
            // Plan md must carry the hidden marker so the reader can show Build.
            if mode == .plan || lowerPath.hasSuffix(".md"),
               lowerPath.contains("plan") || body.contains("connects_plan") || body.contains("- [ ]") {
                body = StudyPlanDocument.wrapAsPlan(body)
            }
            // File I/O + registry; StudyDocumentStore/Workspace notify already hop to main async.
            do {
                let doc = try StudyWorkspaceStore.shared.createFile(
                    named: path,
                    content: body,
                    in: workspaceID
                )
                return .proposeEdit(path: doc.title, content: body)
            } catch {
                return .text("error: \(error.localizedDescription)")
            }
        case .deleteFile:
            if mode == .ask {
                return .text("error: delete_file not allowed in ask mode")
            }
            if mode == .plan {
                return .text("error: delete_file not allowed in plan mode")
            }
            let path = (call.arguments["path"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return .text("error: path required") }
            if let denied = mutateScopeError(tool: "delete_file", path: path, activeFileName: active, mode: mode) {
                return .text(denied)
            }
            let name = Self.canonicalizeMutatePath(path, activeFileName: active)
            do {
                try StudyWorkspaceStore.shared.deleteFile(named: name, in: workspaceID)
                return .text("deleted \(name)")
            } catch {
                return .text("error: \(error.localizedDescription)")
            }
        case .askUser:
            let prompt = call.arguments["prompt"] ?? call.arguments["query"] ?? "请补充说明"
            return .askUser(prompt: prompt)
        case .updatePlan:
            let plan = call.arguments["plan"] ?? call.arguments["body"] ?? ""
            return .plan(plan.isEmpty ? "(empty plan)" : plan)
        case .spawnSubagent:
            let roleRaw = (call.arguments["role"] ?? "explore").lowercased()
            let role = AgentSubagentRunner.Role(rawValue: roleRaw) ?? .explore
            let task = call.arguments["task"] ?? call.arguments["prompt"] ?? "explore workspace"
            let paths = (call.arguments["paths"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            // Model is injected by orchestrator via thread-local / static context.
            let model = AgentOrchestrator.shared.subagentModel
            let summary = AgentSubagentRunner.run(
                role: role,
                task: task,
                paths: paths,
                workspaceID: workspaceID,
                mode: mode,
                model: model
            )
            return .subagentSummary(summary)
        }
    }

    private static func readWorkspaceFile(_ relative: String, workspaceID: String) -> String {
        let candidates: [URL] = {
            if let url = try? StudyWorkspaceStore.shared.fileURL(relativePath: relative, in: workspaceID) {
                return [url]
            }
            return []
        }()
        // Also try last-path-component match for older prompts that omit folders.
        let urls: [URL] = {
            var out = candidates
            if let folder = try? StudyWorkspaceStore.shared.folderURL(for: workspaceID) {
                let leaf = (relative as NSString).lastPathComponent
                for name in StudyWorkspaceStore.shared.listFileNames(in: workspaceID) where (name as NSString).lastPathComponent == leaf {
                    if let u = try? StudyWorkspaceStore.shared.fileURL(relativePath: name, in: workspaceID) {
                        out.append(u)
                    }
                }
                out.append(folder.appendingPathComponent(leaf))
            }
            return out
        }()
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                continue
            }
            if text.count > 24_000 {
                return String(text.prefix(24_000)) + "\n…(truncated)"
            }
            return text
        }
        return "error: cannot read \(relative)"
    }

    private static func grepWorkspace(query: String, workspaceID: String) -> String {
        guard !query.isEmpty else { return "error: query required" }
        var hits: [String] = []
        for name in StudyWorkspaceStore.shared.listFileNames(in: workspaceID) {
            guard let url = try? StudyWorkspaceStore.shared.fileURL(relativePath: name, in: workspaceID),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (i, line) in text.components(separatedBy: .newlines).enumerated() {
                if line.localizedCaseInsensitiveContains(query) {
                    hits.append("\(name):\(i + 1): \(line.prefix(200))")
                    if hits.count >= 40 { return hits.joined(separator: "\n") }
                }
            }
        }
        return hits.isEmpty ? "(no matches)" : hits.joined(separator: "\n")
    }

    private static func resolvedActiveFileName(_ explicit: String?) -> String? {
        if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return (explicit as NSString).lastPathComponent
        }
        return ConversationStore.shared.currentConversation?.studyActiveFileName
    }

    private static func canonicalizeMutatePath(_ path: String, activeFileName: String?) -> String {
        let name = (path as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = name.lowercased()
        if lower == "current" || lower == "." || lower == "active",
           let active = activeFileName, !active.isEmpty {
            return active
        }
        return name
    }

    /// Returns an error string when the mutate is out of Study active-file scope.
    private static func mutateScopeError(
        tool: String,
        path: String,
        activeFileName: String?,
        mode: StudyAgentMode
    ) -> String? {
        // Plan mode may create plan markdown anywhere in the folder.
        if tool == "create_file", mode == .plan { return nil }
        // Agent/Ask: create_file never — folder growth is UI-only (+ / import).
        if tool == "create_file" {
            if let active = activeFileName, !active.isEmpty {
                return "error: create_file blocked — Study may only edit the open file (\(active)). Create other files via UI (+), then switch to them."
            }
            return "error: create_file blocked — Study may only edit the currently open file. Create files via UI (+)."
        }
        guard let active = activeFileName, !active.isEmpty else {
            return "error: \(tool) blocked — no open Study file; open a file in the folder first"
        }
        let name = (path as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = name.lowercased()
        if lower == "current" || lower == "." || lower == "active" { return nil }
        if name.caseInsensitiveCompare(active) == .orderedSame { return nil }
        return "error: \(tool) blocked for \(name) — Study edits only the currently open file (\(active)). Switch files in the reader title, then retry."
    }
}
