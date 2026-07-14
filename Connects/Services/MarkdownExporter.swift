import Foundation

enum MarkdownExporter {
    static var documentsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("ConnectsMarkdown", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileURL(for conversation: Conversation) -> URL {
        let safe = sanitize(conversation.title.isEmpty ? conversation.id : conversation.title)
        return documentsDirectory.appendingPathComponent("\(safe)__\(conversation.id.prefix(8)).md")
    }

    /// Full chat export — ChatGPT-style readable Markdown (entire transcript).
    static func render(_ conversation: Conversation) -> String {
        var lines: [String] = []
        lines.append("---")
        lines.append("title: \"\(escapeYAML(conversation.title))\"")
        lines.append("model: \"\(conversation.model.displayName)\"")
        lines.append("model_id: \"\(conversation.model.modelId)\"")
        lines.append("updated: \"\(formatDate(conversation.updatedAt))\"")
        lines.append("id: \"\(conversation.id)\"")
        if let fork = conversation.forkedFromID {
            lines.append("forked_from: \"\(fork)\"")
        }
        if conversation.isArchived {
            lines.append("archived: true")
        }
        lines.append("exported_by: Connects")
        lines.append("---")
        lines.append("")
        lines.append("# \(conversation.title)")
        lines.append("")
        lines.append("> 模型：\(conversation.model.displayName) · 更新：\(formatDate(conversation.updatedAt))")
        lines.append("")

        let msgs = conversation.messages.filter { !$0.isStreaming }
        if msgs.isEmpty {
            lines.append("_（空对话）_")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        for (idx, msg) in msgs.enumerated() {
            let role: String
            switch msg.role {
            case .user: role = "用户"
            case .assistant: role = "助手"
            case .system: role = "系统"
            }
            lines.append("## \(idx + 1). \(role)")
            lines.append("")
            lines.append("*\(formatDate(msg.createdAt))*")
            lines.append("")

            if msg.hasImage {
                lines.append("> 📎 本条含图片附件（导出为 Markdown 文本时不内嵌二进制）")
                lines.append("")
            }
            let imageDescription = msg.imageDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !imageDescription.isEmpty {
                lines.append("<details>")
                lines.append("<summary>图片文字描述</summary>")
                lines.append("")
                lines.append(imageDescription)
                lines.append("")
                lines.append("</details>")
                lines.append("")
            }

            let search = msg.searchProcessContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !search.isEmpty {
                lines.append("<details>")
                lines.append("<summary>联网检索</summary>")
                lines.append("")
                lines.append(search)
                lines.append("")
                lines.append("</details>")
                lines.append("")
            }

            let think = msg.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !think.isEmpty {
                lines.append("<details>")
                lines.append("<summary>思考过程</summary>")
                lines.append("")
                lines.append(think)
                lines.append("")
                lines.append("</details>")
                lines.append("")
            }

            let body = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                lines.append(body)
                lines.append("")
            } else if !msg.hasImage && think.isEmpty && search.isEmpty {
                lines.append("_（无正文）_")
                lines.append("")
            }

            lines.append("---")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Plain-text variant for clipboard (no HTML details).
    static func renderPlain(_ conversation: Conversation) -> String {
        var parts: [String] = []
        parts.append(conversation.title)
        parts.append("模型：\(conversation.model.displayName)")
        parts.append("")
        for msg in conversation.messages where !msg.isStreaming {
            let role: String
            switch msg.role {
            case .user: role = "用户"
            case .assistant: role = "助手"
            case .system: role = "系统"
            }
            let body = msg.copyableText
            guard !body.isEmpty else { continue }
            parts.append("【\(role)】")
            parts.append(body)
            parts.append("")
        }
        return parts.joined(separator: "\n")
    }

    @discardableResult
    static func write(_ conversation: Conversation) -> URL? {
        let md = render(conversation)
        let url = fileURL(for: conversation)
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Compact context for AI title / follow-ups (text only).
    static func contextSnippet(_ conversation: Conversation, maxChars: Int = 2400) -> String {
        var parts: [String] = []
        for msg in conversation.messages where !msg.isStreaming {
            let role = msg.role == .user ? "User" : "Assistant"
            let text = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            parts.append("\(role): \(text)")
        }
        var joined = parts.joined(separator: "\n\n")
        if joined.count > maxChars {
            joined = String(joined.suffix(maxChars))
        }
        return joined
    }

    private static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "chat" : trimmed).prefix(40))
    }

    private static func escapeYAML(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
