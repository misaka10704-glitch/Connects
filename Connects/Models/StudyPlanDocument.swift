import Foundation

/// Parsed Connects workspace plan markdown (`connects_plan` frontmatter + todo checklist).
struct StudyPlanDocument: Equatable {
    struct TodoItem: Equatable {
        var title: String
        var done: Bool
    }

    var isPlan: Bool
    var todos: [TodoItem]
    /// Body after frontmatter (may still contain todo lines).
    var bodyMarkdown: String

    static func parse(_ markdown: String) -> StudyPlanDocument {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        var isPlan = false
        var body = trimmed

        if trimmed.hasPrefix("---") {
            let lines = trimmed.components(separatedBy: .newlines)
            if lines.count >= 2 {
                var end = 1
                while end < lines.count, lines[end] != "---" { end += 1 }
                if end < lines.count {
                    let fm = lines[1..<end].joined(separator: "\n")
                    isPlan = Self.frontmatterDeclaresPlan(fm)
                    body = lines[(end + 1)...].joined(separator: "\n")
                }
            }
        }

        // Hidden markers outside YAML (HTML comment / sentinel line).
        if !isPlan {
            let lower = trimmed.lowercased()
            if lower.contains("<!-- connects_plan")
                || lower.contains("connects_plan: true")
                || lower.contains("connects_plan:true") {
                isPlan = true
            }
        }

        var todos: [TodoItem] = []
        for line in body.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- [x] ") || t.hasPrefix("- [X] ") {
                todos.append(TodoItem(title: String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces), done: true))
            } else if t.hasPrefix("- [ ] ") {
                todos.append(TodoItem(title: String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces), done: false))
            }
        }

        return StudyPlanDocument(isPlan: isPlan, todos: todos, bodyMarkdown: body)
    }

    private static func frontmatterDeclaresPlan(_ fm: String) -> Bool {
        let lower = fm.lowercased()
        guard lower.range(of: "connects_plan:") != nil else { return false }
        if lower.contains("connects_plan: false")
            || lower.contains("connects_plan:false")
            || lower.contains("connects_plan: 0")
            || lower.contains("connects_plan:0")
            || lower.contains("connects_plan: no")
            || lower.contains("connects_plan:no") {
            return false
        }
        return true
    }

    /// Ensure plan markdown has the required frontmatter.
    static func wrapAsPlan(_ markdown: String) -> String {
        let parsed = parse(markdown)
        if parsed.isPlan { return markdown }
        let body = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            return """
            ---
            connects_plan: true
            ---

            ## Todos
            - [ ] 
            """
        }
        return """
        ---
        connects_plan: true
        ---

        \(body)
        """
    }
}
