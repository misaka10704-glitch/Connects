import Foundation

enum CodeEditRangeKind: String {
    case selection
    case full
}

struct CodeEditProposal {
    let rangeKind: CodeEditRangeKind
    let replacement: String
    /// Assistant reply with the machine block removed (for chat display).
    let displayContent: String
    /// Target path from `path:` header; `nil` / `current` means active file.
    let targetPath: String?
}

enum CodeEditApplyTools {
    static let beginMarker = "<<<CONNECTS_EDIT"
    static let endMarker = "CONNECTS_EDIT>>>"
    static let maxChars = 48_000

    /// Authorization + optional proposal protocol injected when「AI 编辑」is on.
    /// Independent of deep-thinking; models may edit with thinking off.
    static let authorizationPrefix: String = """
    ## CONNECTS_CODE_EDIT (optional)
    You MAY propose an edit to the current study code/text file, but you MUST NOT edit on every turn.
    - Explain / answer questions → normal Markdown only. Do NOT emit CONNECTS_EDIT.
    - When the user wants code written or changed, append exactly one machine block at the end of your reply (after any explanation):

    <<<CONNECTS_EDIT
    path: current
    range: full
    ```
    replacement body only
    ```
    CONNECTS_EDIT>>>

    Rules:
    - `path: current` (or omit path) edits ONLY the currently open Study file.
    - Never set `path` to another workspace file — Study will reject cross-file edits. User switches files in the reader title first.
    - Prefer `range: full` when writing/replacing the file (or most of it). Use `range: selection` only if replacing the user's current selection.
    - To clear the file: use `range: full` with an empty fence body (still emit the full CONNECTS_EDIT block).
    - Inside the fence: only the code/text to paste — no commentary.
    - Before the CONNECTS_EDIT block, always write one short sentence summarizing the change (so the chat is not empty).
    - At most one CONNECTS_EDIT block per reply. Without this block, nothing is written to the file.
    - The block MUST be closed with CONNECTS_EDIT>>> in the same reply (or continuation). Never leave <<<CONNECTS_EDIT open.
    """

    static func strippingAuthorization(from prefix: String) -> String {
        var s = prefix
        if let r = s.range(of: authorizationPrefix) {
            s.removeSubrange(r)
        } else if let start = s.range(of: "## CONNECTS_CODE_EDIT") {
            // Best-effort strip of a previously injected block through the rules footer.
            if let endMark = s.range(of: "At most one CONNECTS_EDIT block per reply") {
                let end = s.index(endMark.upperBound, offsetBy: 0, limitedBy: s.endIndex) ?? s.endIndex
                // Include rest of that line.
                var cutEnd = end
                if let nl = s[end...].firstIndex(of: "\n") {
                    cutEnd = s.index(after: nl)
                }
                s.removeSubrange(start.lowerBound..<cutEnd)
            } else {
                s.removeSubrange(start.lowerBound..<s.endIndex)
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseEditBlock(from content: String) -> CodeEditProposal? {
        // Tolerate whitespace / case variants models often emit.
        guard let begin = findConnectsEditBegin(in: content),
              let end = content.range(
                of: "CONNECTS_EDIT>>>",
                options: [.caseInsensitive],
                range: begin.upperBound..<content.endIndex
              ) else {
            return nil
        }
        let headerAndBody = String(content[begin.upperBound..<end.lowerBound])
        let display = (
            String(content[..<begin.lowerBound]) + String(content[end.upperBound...])
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let lines = headerAndBody.components(separatedBy: .newlines)
        // Default to full-file for write/edit intents when model omits range.
        var rangeKind = CodeEditRangeKind.full
        var targetPath: String?
        var collectingCode = false
        var codeLines: [String] = []
        var fenceOpened = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if lower.hasPrefix("range:") {
                let value = trimmed.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if value.hasPrefix("selection") || value.hasPrefix("sel") {
                    rangeKind = .selection
                } else if value.hasPrefix("full")
                            || value.hasPrefix("file")
                            || value.hasPrefix("all")
                            || value.hasPrefix("entire") {
                    rangeKind = .full
                }
                continue
            }
            if lower.hasPrefix("path:") {
                let value = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    targetPath = value
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                if !fenceOpened {
                    fenceOpened = true
                    collectingCode = true
                } else {
                    collectingCode = false
                }
                continue
            }
            if collectingCode {
                codeLines.append(line)
            }
        }

        var replacement = codeLines.joined(separator: "\n")
        if replacement.isEmpty {
            let body = lines.filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                let lower = t.lowercased()
                return !t.isEmpty
                    && !lower.hasPrefix("path:")
                    && !lower.hasPrefix("range:")
                    && !t.hasPrefix("```")
            }.joined(separator: "\n")
            replacement = body
        }
        replacement = stripCodeFence(replacement)
        // Empty body is valid only for full-file clear; selection must replace something.
        if replacement.isEmpty, rangeKind != .full { return nil }
        return CodeEditProposal(
            rangeKind: rangeKind,
            replacement: replacement,
            displayContent: display,
            targetPath: targetPath
        )
    }

    /// `true` when a CONNECTS_EDIT begin marker exists without a matching end (truncated stream).
    static func hasIncompleteEditBlock(_ content: String) -> Bool {
        guard let begin = findConnectsEditBegin(in: content) else { return false }
        return content.range(
            of: endMarker,
            options: [.caseInsensitive],
            range: begin.upperBound..<content.endIndex
        ) == nil
    }

    /// Nudge for auto-continue when the edit machine block was cut mid-stream.
    static let incompleteEditContinueNudge: String = """
    你的 CONNECTS_EDIT 编辑块尚未闭合（缺少结尾的 CONNECTS_EDIT>>>）。
    请从中断处继续：
    - 不要重复已经输出的内容
    - 不要再开新的 <<<CONNECTS_EDIT
    - 完成 fence 内剩余代码/文本后，输出 CONNECTS_EDIT>>>
    """

    /// Truncate trailing incomplete `<<<` / `<<<CONNECTS…` so stream paint never leaks markers.
    private static func truncatingIncompleteConnectsMarker(in raw: String) -> String? {
        guard let arrows = raw.range(of: "<<<", options: .backwards) else { return nil }
        guard AgentTools.looksLikeIncompleteConnectsMarkerSuffix(raw[arrows.upperBound...]) else {
            return nil
        }
        return String(raw[..<arrows.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `<<<CONNECTS_EDIT` with optional spaces after `<<<` (models often insert them).
    private static func findConnectsEditBegin(in content: String) -> Range<String.Index>? {
        if let exact = content.range(of: "<<<CONNECTS_EDIT", options: [.caseInsensitive]) {
            return exact
        }
        // <<< + spaces + CONNECTS_EDIT
        guard let marker = content.range(of: "CONNECTS_EDIT", options: [.caseInsensitive]) else {
            return nil
        }
        let prefix = content[content.startIndex..<marker.lowerBound]
        guard let arrows = prefix.range(of: "<<<", options: .backwards) else { return nil }
        let between = content[arrows.upperBound..<marker.lowerBound]
        guard between.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        return arrows.lowerBound..<marker.upperBound
    }

    /// Chat-bubble text: never show raw CONNECTS_EDIT fences (streaming or finished).
    /// While the edit block is open, surface live size/line stats + a short code tail
    /// (same idea as deep-thinking live preview) so large writes do not look frozen.
    /// Hot-path: after begin locks, only the newly streamed suffix is scanned for the end marker.
    private static var visUTF8 = -1
    private static var visBeginUTF16 = -1
    private static var visScannedUTF16 = 0
    private static var visOpen = false
    private static var visBefore = ""
    private static var visResult = ""
    /// Per-message `(utf8Count → visible)` so cells/layout skip re-scan on reuse.
    private static var displayByMessage: [String: (utf8: Int, visible: String)] = [:]

    static func chatVisibleContent(for messageID: String, raw: String) -> String {
        let utf8 = raw.utf8.count
        if let hit = displayByMessage[messageID], hit.utf8 == utf8 {
            return hit.visible
        }
        let visible = chatVisibleContent(raw)
        displayByMessage[messageID] = (utf8, visible)
        if displayByMessage.count > 64 {
            displayByMessage.removeAll(keepingCapacity: true)
            displayByMessage[messageID] = (utf8, visible)
        }
        return visible
    }

    static func chatVisibleContent(_ raw: String) -> String {
        let utf8 = raw.utf8.count
        let beginOpts: String.CompareOptions = [.caseInsensitive]
        let endMarker = "CONNECTS_EDIT>>>"

        // Reuse half-open session: probe only the newly appended UTF-16 tail for end,
        // but refresh the live status whenever bytes grew.
        if visOpen, visBeginUTF16 >= 0, utf8 >= visUTF8, visUTF8 >= 0 {
            let u16 = raw.utf16
            if visBeginUTF16 <= u16.count {
                let overlap = endMarker.utf16.count
                let fromUTF16 = max(visBeginUTF16, max(0, visScannedUTF16 - overlap))
                if fromUTF16 <= u16.count,
                   let fromIdx = String.Index(
                    u16.index(u16.startIndex, offsetBy: fromUTF16),
                    within: raw
                   ) {
                    if raw.range(
                        of: endMarker,
                        options: beginOpts,
                        range: fromIdx..<raw.endIndex
                    ) == nil {
                        let payload: String = {
                            if let begin = findConnectsEditBegin(in: raw) {
                                return String(raw[begin.upperBound...])
                            }
                            return ""
                        }()
                        let result = openEditStreamStatus(before: visBefore, payload: payload)
                        visScannedUTF16 = u16.count
                        visUTF8 = utf8
                        visResult = result
                        return result
                    }
                    // Fall through — block just closed.
                }
            }
        }

        // Cheap reject for normal replies (no edit protocol).
        if utf8 < 14 || (!raw.contains("<<<") && !raw.contains("CONNECTS_EDIT") && !raw.contains("connects_edit")) {
            resetStreamVisibleCache()
            return raw
        }

        guard let begin = findConnectsEditBegin(in: raw) else {
            // Incomplete `<<<CONNECTS_EDIT` prefix mid-stream — hide from the bubble.
            if let truncated = truncatingIncompleteConnectsMarker(in: raw) {
                resetStreamVisibleCache()
                return truncated
            }
            resetStreamVisibleCache()
            return raw
        }
        let before = String(raw[..<begin.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let beginUTF16 = raw.utf16.distance(from: raw.utf16.startIndex, to: begin.lowerBound)

        if let end = raw.range(
            of: endMarker,
            options: beginOpts,
            range: begin.upperBound..<raw.endIndex
        ) {
            let after = String(raw[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let merged = [before, after]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let result = merged.isEmpty ? "（文件编辑内容已隐藏）" : merged
            visUTF8 = utf8
            visBeginUTF16 = beginUTF16
            visScannedUTF16 = raw.utf16.count
            visOpen = false
            visBefore = ""
            visResult = result
            return result
        }

        let payload = String(raw[begin.upperBound...])
        let result = openEditStreamStatus(before: before, payload: payload)
        visUTF8 = utf8
        visBeginUTF16 = beginUTF16
        visScannedUTF16 = raw.utf16.count
        visOpen = true
        visBefore = before
        visResult = result
        return result
    }

    /// Live bubble while `<<<CONNECTS_EDIT` is open: stats + last few code lines.
    private static func openEditStreamStatus(before: String, payload: String) -> String {
        let bytes = payload.utf8.count
        let lineBreaks = payload.reduce(into: 0) { count, ch in
            if ch == "\n" { count += 1 }
        }
        let lines = payload.isEmpty ? 0 : lineBreaks + 1
        let sizeLabel: String
        if bytes < 1024 {
            sizeLabel = "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            sizeLabel = String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            sizeLabel = String(format: "%.2f MB", Double(bytes) / (1024.0 * 1024.0))
        }
        let header = "（正在生成文件编辑 · \(sizeLabel) · \(lines) 行）"
        let tail = editStreamTailPreview(payload)
        var parts: [String] = []
        if !before.isEmpty { parts.append(before) }
        parts.append(header)
        if !tail.isEmpty { parts.append(tail) }
        return parts.joined(separator: "\n\n")
    }

    /// Last few non-meta lines of the in-flight edit payload (thinking-style tail).
    private static func editStreamTailPreview(_ payload: String, maxLines: Int = 3, lineCharCap: Int = 96) -> String {
        let rows = payload.components(separatedBy: "\n").filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return false }
            let lower = t.lowercased()
            if lower.hasPrefix("path:") || lower.hasPrefix("range:") { return false }
            if t.hasPrefix("```") { return false }
            return true
        }
        guard !rows.isEmpty else { return "" }
        let slice = Array(rows.suffix(maxLines))
        let clipped = slice.map { line -> String in
            if line.count <= lineCharCap { return line }
            return "…" + String(line.suffix(lineCharCap))
        }
        let body = clipped.joined(separator: "\n")
        return rows.count > maxLines ? "…\n" + body : body
    }

    private static func resetStreamVisibleCache() {
        visUTF8 = -1
        visBeginUTF16 = -1
        visScannedUTF16 = 0
        visOpen = false
        visBefore = ""
        visResult = ""
    }

    static func clearVisibleCache() {
        resetStreamVisibleCache()
        displayByMessage.removeAll(keepingCapacity: true)
    }

    static func stripCodeFence(_ raw: String) -> String {
        // Only unwrap a markdown fence. Do NOT trim the payload — trailing `\n`
        // and leading indentation are meaningful for source files.
        let probe = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard probe.hasPrefix("```") else { return raw }

        var text = probe
        if let firstNL = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNL)...])
        } else {
            return ""
        }
        // Drop closing fence line if present (allow trailing whitespace after ```).
        if let close = text.range(of: "\n```", options: .backwards) {
            let after = text[close.upperBound...]
            if after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = String(text[..<close.lowerBound])
            }
        } else if text.hasSuffix("```") {
            text = String(text.dropLast(3))
            if text.hasSuffix("\n") {
                text = String(text.dropLast())
            }
        }
        return text
    }

    static func resolveTargetRange(text: String,
                                   selectedRange: NSRange,
                                   kind: CodeEditRangeKind) -> NSRange {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        if kind == .full { return full }
        let clamped = NSIntersectionRange(selectedRange, full)
        if clamped.length > 0 { return clamped }
        // No selection → full file (including empty / write).
        return full
    }

    static func composeAfter(before: String, range: NSRange, replacement: String) -> String {
        let ns = before as NSString
        let safe = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        return ns.replacingCharacters(in: safe, with: replacement)
    }

    static func validateAlignment(before: String, after: String, range: NSRange, replacement: String) -> Bool {
        composeAfter(before: before, range: range, replacement: replacement) == after
    }
}
