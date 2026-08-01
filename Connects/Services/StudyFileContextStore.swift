import Foundation

enum StudyContextScope: String, Codable, Equatable {
    case auto
    case fullFile
    case selection
    case sectionOrPage
    case resync
}

struct StudyFilePinState {
    var pinID: String
    var sha8: String
    var lineCount: Int
    var lastPinnedTurn: Int
    var lastFullText: String
    var dirtySincePin: Bool
}

/// Session-scoped code/text context: pin once, then FILE_REF / FILE_DELTA.
final class StudyFileContextStore {
    static let shared = StudyFileContextStore()

    private var pins: [String: StudyFilePinState] = [:] // conversationID
    private var scopes: [String: StudyContextScope] = [:]
    private var turnCounters: [String: Int] = [:]
    private let pinBudgetChars = 12_000
    private let rePinEveryTurns = 4

    private init() {}

    func scope(for conversationID: String) -> StudyContextScope {
        scopes[conversationID] ?? .auto
    }

    func setScope(_ scope: StudyContextScope, for conversationID: String) {
        if scope == .resync {
            pins.removeValue(forKey: conversationID)
            scopes[conversationID] = .auto
            return
        }
        scopes[conversationID] = scope
    }

    func reset(conversationID: String) {
        pins.removeValue(forKey: conversationID)
        turnCounters[conversationID] = 0
    }

    func markDirty(conversationID: String) {
        pins[conversationID]?.dirtySincePin = true
    }

    /// Build code/text apiContextPrefix body (without trailing user question).
    func buildCodeContextPrefix(
        conversationID: String,
        document: StudyDocument,
        fullText: String,
        selection: String?,
        forceFull: Bool,
        workspaceID: String? = nil
    ) -> String {
        let sha = StudyDocumentStore.shared.contentSHA8(for: document.id)
        let lines = fullText.components(separatedBy: .newlines)
        let lineCount = lines.count
        let lang = document.textLanguage?.rawValue ?? "text"
        let path = document.displayPath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? document.title
        let turn = (turnCounters[conversationID] ?? 0) + 1
        turnCounters[conversationID] = turn

        let scope = scopes[conversationID] ?? .auto
        let wantSelectionOnly = scope == .selection
        var shouldPin = forceFull || scope == .fullFile || scope == .resync || pins[conversationID] == nil
        if let pin = pins[conversationID] {
            if pin.sha8 != sha { shouldPin = true }
            if turn - pin.lastPinnedTurn >= rePinEveryTurns { shouldPin = true }
            if pin.dirtySincePin { shouldPin = false } // prefer delta unless other triggers
        }
        if scope == .resync {
            shouldPin = true
            scopes[conversationID] = .auto
        }

        var parts: [String] = []
        if let workspaceID,
           let workspaceBlock = Self.workspaceListingBlock(workspaceID: workspaceID, activeFile: path) {
            parts.append(workspaceBlock)
        }
        parts.append("[阅读上下文 · 代码 · \(document.kindLabel)]")
        parts.append("path: \(path)")
        parts.append("lang: \(lang)  lines: \(lineCount)  sha: \(sha)")

        if wantSelectionOnly {
            let sel = trimmedSelection(selection, fullText: fullText, lines: lines)
            parts.append("## SELECTION")
            parts.append(sel.isEmpty ? "（无选区，以下为光标附近）\n" + windowAround(lines: lines, center: 0, radius: 40) : sel)
            return parts.joined(separator: "\n")
        }

        if let pin = pins[conversationID], pin.dirtySincePin, !shouldPin {
            let delta = Self.lineDelta(old: pin.lastFullText, new: fullText)
            if !delta.isEmpty, delta.count < pinBudgetChars / 2 {
                parts.append("## FILE_REF pin:\(pin.pinID) sha:\(sha) lines:\(lineCount)")
                parts.append("（文件已修改，以下为相对上次钉住的增量）")
                parts.append("## FILE_DELTA")
                parts.append(delta)
                if let sel = selection?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty {
                    parts.append("## SELECTION")
                    parts.append(String(sel.prefix(2_000)))
                }
                pins[conversationID]?.lastFullText = fullText
                pins[conversationID]?.sha8 = sha
                pins[conversationID]?.dirtySincePin = false
                pins[conversationID]?.lineCount = lineCount
                return parts.joined(separator: "\n")
            }
            shouldPin = true
        }

        if shouldPin || pins[conversationID] == nil {
            let pinID = pins[conversationID]?.pinID ?? String(UUID().uuidString.prefix(8))
            let body = pinnedBody(fullText: fullText, lines: lines, language: document.textLanguage ?? .plain)
            parts.append("## FILE [pin:\(pinID)] sha=\(sha)")
            parts.append(body)
            if let sel = selection?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty {
                parts.append("## SELECTION")
                parts.append(String(sel.prefix(2_000)))
            }
            pins[conversationID] = StudyFilePinState(
                pinID: pinID,
                sha8: sha,
                lineCount: lineCount,
                lastPinnedTurn: turn,
                lastFullText: fullText,
                dirtySincePin: false
            )
            return parts.joined(separator: "\n")
        }

        let pin = pins[conversationID]!
        parts.append("## FILE_REF pin:\(pin.pinID) sha:\(sha) lines:\(lineCount)")
        parts.append("（全文已在本会话较早轮次钉住；内容未变。）")
        if let sel = selection?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty {
            parts.append("## SELECTION")
            parts.append(String(sel.prefix(2_000)))
        } else {
            parts.append("## NEAR_CURSOR")
            parts.append(windowAround(lines: lines, center: 0, radius: 30))
        }
        return parts.joined(separator: "\n")
    }

    private static func workspaceListingBlock(workspaceID: String, activeFile: String) -> String? {
        let names = StudyWorkspaceStore.shared.listFileNames(in: workspaceID)
        guard !names.isEmpty else { return nil }
        let wsTitle = StudyWorkspaceStore.shared.workspace(id: workspaceID)?.title ?? "Workspace"
        var lines = ["## WORKSPACE · \(wsTitle)"]
        for name in names.prefix(40) {
            let mark = name == activeFile ? " ★" : ""
            lines.append("- \(name)\(mark)")
        }
        if names.count > 40 {
            lines.append("- … +\(names.count - 40) more")
        }
        lines.append("Prefer CONNECTS_TOOL (list_dir/read_file/grep/propose_edit). CONNECTS_EDIT path: <filename> also works.")
        return lines.joined(separator: "\n")
    }

    private func pinnedBody(fullText: String, lines: [String], language: StudyTextLanguage) -> String {
        if fullText.count <= pinBudgetChars {
            return numbered(lines)
        }
        if language == .verilog {
            return verilogModuleSlice(lines: lines)
        }
        // Head + tail fallback
        let head = Array(lines.prefix(200))
        let tail = Array(lines.suffix(80))
        var out = numbered(head)
        out += "\n… (\(lines.count - head.count - tail.count) lines omitted) …\n"
        let start = max(lines.count - tail.count + 1, head.count + 1)
        for (i, line) in tail.enumerated() {
            out += String(format: "%5d|%@\n", start + i, line)
        }
        return out
    }

    private func verilogModuleSlice(lines: [String]) -> String {
        var modules: [(name: String, start: Int, end: Int)] = []
        var current: (String, Int)?
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let r = trimmed.range(of: #"^\s*module\s+([A-Za-z_][A-Za-z0-9_$]*)"#, options: .regularExpression) {
                let namePart = String(trimmed[r])
                let name = namePart.split(separator: " ").last.map(String.init) ?? "module"
                if let cur = current {
                    modules.append((cur.0, cur.1, i - 1))
                }
                current = (name, i)
            } else if trimmed.hasPrefix("endmodule"), let cur = current {
                modules.append((cur.0, cur.1, i))
                current = nil
            }
        }
        if let cur = current {
            modules.append((cur.0, cur.1, lines.count - 1))
        }
        guard !modules.isEmpty else {
            return String(numbered(Array(lines.prefix(400))).prefix(pinBudgetChars))
        }
        // Prefer largest module (often the DUT)
        let focus = modules.max(by: { ($0.end - $0.start) < ($1.end - $1.start) })!
        var outline = "## MODULE_OUTLINE\n"
        for m in modules {
            outline += "L\(m.start + 1)–L\(m.end + 1): \(m.name)\n"
        }
        let slice = Array(lines[focus.start...focus.end])
        var body = outline + "## ACTIVE_MODULE \(focus.name)\n" + numbered(slice, start: focus.start + 1)
        if body.count > pinBudgetChars {
            body = String(body.prefix(pinBudgetChars)) + "\n…(truncated)…"
        }
        return body
    }

    private func numbered(_ lines: [String], start: Int = 1) -> String {
        var out = ""
        for (i, line) in lines.enumerated() {
            out += String(format: "%5d|%@\n", start + i, line)
        }
        return out
    }

    private func windowAround(lines: [String], center: Int, radius: Int) -> String {
        guard !lines.isEmpty else { return "" }
        let c = min(max(center, 0), lines.count - 1)
        let lo = max(0, c - radius)
        let hi = min(lines.count - 1, c + radius)
        return numbered(Array(lines[lo...hi]), start: lo + 1)
    }

    private func trimmedSelection(_ selection: String?, fullText: String, lines: [String]) -> String {
        if let sel = selection?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty {
            return String(sel.prefix(4_000))
        }
        return windowAround(lines: lines, center: 0, radius: 40)
    }

    private static func lineDelta(old: String, new: String) -> String {
        let a = old.components(separatedBy: .newlines)
        let b = new.components(separatedBy: .newlines)
        if a == b { return "" }
        var parts: [String] = []
        let maxLines = min(max(a.count, b.count), 400)
        for i in 0..<maxLines {
            let left = i < a.count ? a[i] : nil
            let right = i < b.count ? b[i] : nil
            if left == right { continue }
            if let right = right {
                parts.append(String(format: "+%d|%@", i + 1, right))
            } else if left != nil {
                parts.append(String(format: "-%d|%@", i + 1, left!))
            }
            if parts.count > 200 { break }
        }
        return parts.joined(separator: "\n")
    }
}
