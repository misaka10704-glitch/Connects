import Foundation

enum AITitleGenerator {
    static func generateIfNeeded(conversationID: String) {
        guard let conv = ConversationStore.shared.conversations.first(where: { $0.id == conversationID }),
              !conv.titleLocked else { return }

        // Prefer refining only while still placeholder-like, or short provisional titles
        let canRefine = conv.title == "新对话"
            || conv.title.hasSuffix("（分叉）")
            || conv.title.count <= 20
        guard canRefine else { return }

        let firstUser = conv.messages.first(where: { $0.role == .user })?.content
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let snippet = MarkdownExporter.contextSnippet(conv, maxChars: 800)
        guard !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if !firstUser.isEmpty {
                ConversationStore.shared.applyProvisionalTitle(id: conversationID, fromUserText: firstUser)
            }
            return
        }

        let prompt = ChatMessage(
            role: .user,
            content: """
            请根据下面的对话内容，用不超过12个汉字起一个简短标题。
            只输出标题本身，不要引号、标点、前缀或解释。

            \(snippet)
            """
        )
        APIClient.shared.complete(messages: [prompt], model: conv.model) { result in
            switch result {
            case .success(let title):
                let cleaned = title
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .newlines).first ?? title
                if cleaned.count <= 30, !cleaned.isEmpty {
                    ConversationStore.shared.applyAITitle(id: conversationID, title: cleaned)
                } else if !firstUser.isEmpty {
                    ConversationStore.shared.applyProvisionalTitle(id: conversationID, fromUserText: firstUser)
                }
            case .failure:
                if !firstUser.isEmpty {
                    ConversationStore.shared.applyProvisionalTitle(id: conversationID, fromUserText: firstUser)
                }
            }
        }
    }
}
