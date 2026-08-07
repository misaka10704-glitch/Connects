import Foundation

enum AgentStepKind: String, Codable, Equatable {
    case thought
    case exploring
    case grepped
    case read
    case planned
    case asked
    case subagent
    case edited
    case created
    case deleted
    case tool

    var displayTitle: String {
        switch self {
        case .thought: return "Thinking"
        case .exploring: return "Exploring"
        case .grepped: return "Searching"
        case .read: return "Reading"
        case .planned: return "Planning"
        case .asked: return "Asking"
        case .subagent: return "Exploring"
        case .edited: return "Editing"
        case .created: return "Creating"
        case .deleted: return "Deleting"
        case .tool: return "Running"
        }
    }
}

enum AgentStepStatus: String, Codable, Equatable {
    case running
    case done
    case failed
}

struct AgentProcessStep: Codable, Equatable {
    var id: String
    var kind: AgentStepKind
    var title: String
    var detail: String
    var status: AgentStepStatus
    var startedAt: Date
    var finishedAt: Date?

    init(id: String = UUID().uuidString,
         kind: AgentStepKind,
         title: String,
         detail: String = "",
         status: AgentStepStatus = .running,
         startedAt: Date = Date(),
         finishedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, detail, status, startedAt, finishedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try c.decodeIfPresent(AgentStepKind.self, forKey: .kind) ?? .tool
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        status = try c.decodeIfPresent(AgentStepStatus.self, forKey: .status) ?? .done
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
    }

    mutating func markDone(at date: Date = Date()) {
        status = .done
        finishedAt = date
    }

    /// Cursor composer timeline line (muted grey under the turn).
    var cursorTimelineLine: String {
        let detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .thought:
            if status == .running { return "Thinking" }
            let sec = max(0, Int((finishedAt ?? Date()).timeIntervalSince(startedAt)))
            if sec <= 1 { return "Thought briefly" }
            return "Thought for \(sec)s"
        case .exploring, .subagent:
            if status == .running {
                return title.isEmpty ? "Exploring…" : title
            }
            if !detail.isEmpty { return detail.hasPrefix("Explored") ? detail : "Explored · \(detail)" }
            return title.isEmpty ? "Explored" : title.replacingOccurrences(of: "Exploring", with: "Explored")
        case .grepped:
            if status == .running {
                return title.isEmpty ? "Searching…" : title
            }
            if !detail.isEmpty { return detail }
            return "Searched"
        case .read:
            if status == .running {
                return title.isEmpty ? "Reading…" : title
            }
            if title.hasPrefix("Reading ") {
                return "Read " + title.dropFirst("Reading ".count)
            }
            return title.isEmpty ? "Read file" : title
        case .edited:
            if status == .running {
                return title.isEmpty ? "Editing…" : title
            }
            // Prefer "Edited Foo.swift +4" when detail carries the +N/−M suffix.
            if !detail.isEmpty { return detail }
            if title.hasPrefix("Editing ") {
                return "Edited " + title.dropFirst("Editing ".count)
            }
            return title.isEmpty ? "Edited file" : title
        case .created:
            if status == .running {
                return title.isEmpty ? "Creating…" : title
            }
            if !detail.isEmpty { return detail }
            if title.hasPrefix("Creating ") {
                return "Created " + title.dropFirst("Creating ".count)
            }
            return title.isEmpty ? "Created file" : title
        case .deleted:
            if status == .running {
                return title.isEmpty ? "Deleting…" : title
            }
            if !detail.isEmpty { return detail }
            if title.hasPrefix("Deleting ") {
                return "Deleted " + title.dropFirst("Deleting ".count)
            }
            return title.isEmpty ? "Deleted file" : title
        case .planned:
            return status == .running ? "Updating plan…" : "Updated plan"
        case .asked:
            return status == .running ? "Asking…" : "Asked a question"
        case .tool:
            if status == .running { return title.isEmpty ? "Running…" : title }
            return title.isEmpty ? "Finished" : title
        }
    }
}

enum AgentProcessPhase: String, Codable, Equatable {
    case idle
    case running
    case waitingUser
    case done

    var headerTitle: String {
        switch self {
        case .idle: return "工作流"
        case .running: return "工作中"
        case .waitingUser: return "等待你的回答…"
        case .done: return "已完成"
        }
    }

    /// Cursor-style idle pulse while the model decides the next tool / reply.
    static let planningNextMovesText = "Planning next moves…"
    /// Cursor early-stream status (before tool steps).
    static let thinkingText = "Thinking"
}

/// One completed tool round kept off the transcript table (API-only).
struct AgentToolTurn: Codable, Equatable {
    var id: String
    var assistantContent: String
    var assistantReasoning: String
    var toolResults: String
    var createdAt: Date

    init(id: String = UUID().uuidString,
         assistantContent: String,
         assistantReasoning: String = "",
         toolResults: String,
         createdAt: Date = Date()) {
        self.id = id
        self.assistantContent = assistantContent
        self.assistantReasoning = assistantReasoning
        self.toolResults = toolResults
        self.createdAt = createdAt
    }
}

/// Inline Cursor-style edit card under the agent turn.
struct AgentEditCard: Codable, Equatable {
    var id: String
    var fileName: String
    var documentID: String?
    var additions: Int
    var deletions: Int
    /// Short before/after snippets for the card body (not full file).
    var snippetMinus: String
    var snippetPlus: String

    init(id: String = UUID().uuidString,
         fileName: String,
         documentID: String? = nil,
         additions: Int,
         deletions: Int,
         snippetMinus: String = "",
         snippetPlus: String = "") {
        self.id = id
        self.fileName = fileName
        self.documentID = documentID
        self.additions = additions
        self.deletions = deletions
        self.snippetMinus = snippetMinus
        self.snippetPlus = snippetPlus
    }

    var statsLabel: String {
        if additions > 0, deletions > 0 { return "+\(additions) −\(deletions)" }
        if additions > 0 { return "+\(additions)" }
        if deletions > 0 { return "−\(deletions)" }
        return ""
    }

    var headerLine: String {
        let stats = statsLabel
        return stats.isEmpty ? fileName : "\(fileName)  \(stats)"
    }
}

// MARK: - OpenCode-style ordered timeline parts
// OpenCode (anomalyco/opencode) stores message body as an ordered Part list
// (text | reasoning | tool | step-start | …) keyed by id — updates in place,
// never zip-rebuild. Connects mirrors that for agent chrome.

enum AgentTimelinePartKind: String, Codable, Equatable {
    case thinking
    case meta
    case prose
    case ask
}

/// One stable row in the agent bubble (append-only; meta upserts by step id).
struct AgentTimelinePart: Codable, Equatable {
    var id: String
    var kind: AgentTimelinePartKind
    var text: String
    /// When kind == .meta, optional tool-step kind for styling/coalesce.
    var stepKind: AgentStepKind?
    /// Expandable body (Cursor Thought: full reasoning under "Thought for Ns").
    var detail: String

    init(id: String,
         kind: AgentTimelinePartKind,
         text: String,
         stepKind: AgentStepKind? = nil,
         detail: String = "") {
        self.id = id
        self.kind = kind
        self.text = text
        self.stepKind = stepKind
        self.detail = detail
    }

    /// Meta row id tied to an `AgentProcessStep.id`.
    static func metaID(stepID: String) -> String { "step-\(stepID)" }
    static let liveID = "live"
    /// Sealed Thought row id prefix (Cursor allows many Thoughts under Explored).
    static let thoughtID = "thought"
    static let exploreHeaderID = "explore-header"

    var isExpandableThought: Bool {
        (id == Self.thoughtID || id.hasPrefix("thought-") || stepKind == .thought)
            && !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isExploreChild(stepKind: AgentStepKind?) -> Bool {
        switch stepKind {
        case .thought, .read, .grepped, .exploring, .subagent, .deleted, .planned,
             .edited, .created:
            return true
        default: return false
        }
    }
}

/// Cursor-style paint row: Explored group header + indented children + prose/ask.
enum AgentTimelinePaintRole: String, Equatable {
    case exploreHeader
    case exploreChild
    case live
    case prose
    case ask
    case planned
    case card
}

struct AgentTimelinePaintItem: Equatable {
    var id: String
    var role: AgentTimelinePaintRole
    var text: String
    var detail: String
    var stepKind: AgentStepKind?
    var shimmer: Bool
    var indented: Bool

    init(id: String,
         role: AgentTimelinePaintRole,
         text: String,
         detail: String = "",
         stepKind: AgentStepKind? = nil,
         shimmer: Bool = false,
         indented: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.detail = detail
        self.stepKind = stepKind
        self.shimmer = shimmer
        self.indented = indented
    }
}

enum AgentTimelineSegmentKind: String, Codable, Equatable {
    case thought
    case prose
    case step
    case editCard
    case planning
}

/// Ordered Cursor timeline pieces for a single root assistant turn.
struct AgentTimelineSegment: Codable, Equatable {
    var id: String
    var kind: AgentTimelineSegmentKind
    var text: String
    var editCard: AgentEditCard?

    init(id: String = UUID().uuidString,
         kind: AgentTimelineSegmentKind,
         text: String,
         editCard: AgentEditCard? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.editCard = editCard
    }
}

extension AgentTools {
    /// Human-readable step title for chrome (Cursor-style English timeline).
    static func humanStepTitle(for call: AgentToolCall) -> (kind: AgentStepKind, title: String) {
        switch call.name {
        case .listDir:
            return (.exploring, "Listing files…")
        case .glob:
            let pat = call.arguments["pattern"] ?? call.arguments["path"] ?? "*"
            return (.exploring, "Exploring \(pat)…")
        case .grep:
            let q = call.arguments["query"] ?? ""
            return (.grepped, q.isEmpty ? "Searching…" : "Searching \"\(q)\"…")
        case .readFile:
            let path = (call.arguments["path"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (path as NSString).lastPathComponent
            return (.read, name.isEmpty ? "Reading…" : "Reading \(name)")
        case .proposeEdit:
            let path = (call.arguments["path"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (path as NSString).lastPathComponent
            return (.edited, name.isEmpty ? "Editing…" : "Editing \(name)")
        case .createFile:
            let path = (call.arguments["path"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (path as NSString).lastPathComponent
            return (.created, name.isEmpty ? "Creating…" : "Creating \(name)")
        case .deleteFile:
            let path = (call.arguments["path"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (path as NSString).lastPathComponent
            return (.deleted, name.isEmpty ? "Deleting…" : "Deleting \(name)")
        case .askUser:
            return (.asked, "Asking…")
        case .updatePlan:
            return (.planned, "Updating plan…")
        case .spawnSubagent:
            return (.subagent, "Exploring workspace…")
        }
    }

    /// One-line chrome detail; full tool output stays in TOOL_RESULTS for the model.
    static func humanStepDetailSummary(for call: AgentToolCall, result: AgentToolResult) -> String {
        switch result {
        case .text(let t):
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("error:") {
                return String(trimmed.prefix(80))
            }
            switch call.name {
            case .listDir, .glob:
                if trimmed == "(empty folder)" || trimmed == "(no matches)" {
                    return trimmed == "(empty folder)" ? "Explored · empty" : "Explored · no matches"
                }
                let n = trimmed.split(separator: "\n").filter { !$0.isEmpty }.count
                return n == 1 ? "Explored 1 file" : "Explored \(n) files"
            case .grep:
                if trimmed == "(no matches)" { return "No matches" }
                let n = trimmed.split(separator: "\n").filter { !$0.isEmpty }.count
                return n == 1 ? "1 match" : "\(n) matches"
            case .readFile:
                let path = (call.arguments["path"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let name = (path as NSString).lastPathComponent
                return name.isEmpty ? "Read file" : "Read \(name)"
            case .createFile:
                if trimmed.hasPrefix("error:") {
                    return String(trimmed.prefix(80))
                }
                let path = (call.arguments["path"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let name = (path as NSString).lastPathComponent
                return name.isEmpty ? "Created file" : "Created \(name)"
            case .deleteFile:
                if trimmed.hasPrefix("error:") {
                    return String(trimmed.prefix(80))
                }
                let path = (call.arguments["path"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let name = (path as NSString).lastPathComponent
                if trimmed.lowercased().hasPrefix("deleted") {
                    return name.isEmpty ? "Deleted file" : "Deleted \(name)"
                }
                return name.isEmpty ? "Deleted file" : "Deleted \(name)"
            default:
                return String(trimmed.prefix(60))
            }
        case .askUser(let prompt):
            return String(prompt.prefix(80))
        case .proposeEdit(let path, let body):
            let name = (path as NSString).lastPathComponent
            let fileLabel = name.isEmpty ? "file" : name
            if call.name == .createFile {
                return "Created \(fileLabel)"
            }
            // Light +/- estimate — never run Myers here (main-thread freeze risk).
            if let doc = StudyDocumentStore.shared.documentMatchingPath(path)
                ?? StudyDocumentStore.shared.documents.first(where: {
                    ($0.title as NSString).lastPathComponent == fileLabel
                }),
               let before = StudyDocumentStore.shared.textContent(for: doc.id) {
                let a = before.isEmpty ? 0 : before.components(separatedBy: .newlines).count
                let b = body.isEmpty ? 0 : body.components(separatedBy: .newlines).count
                let add = max(0, b - a)
                let del = max(0, a - b)
                if add > 0, del > 0 { return "Edited \(fileLabel) +\(add) −\(del)" }
                if add > 0 { return "Edited \(fileLabel) +\(add)" }
                if del > 0 { return "Edited \(fileLabel) −\(del)" }
                return "Edited \(fileLabel)"
            }
            let lines = body.isEmpty ? 0 : body.components(separatedBy: .newlines).count
            return lines > 0 ? "Edited \(fileLabel) +\(lines)" : "Edited \(fileLabel)"
        case .plan:
            return "Updated plan"
        case .subagentSummary:
            return "Explored workspace"
        }
    }
}

extension Notification.Name {
    static let agentProcessDidUpdate = Notification.Name("ConnectsAgentProcessDidUpdate")
}
