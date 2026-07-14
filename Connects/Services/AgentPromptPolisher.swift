import Foundation

enum AgentPromptPolisher {
    private static let promptKey = "connects_agent_polisher_prompt"

    static let defaultPrompt = """
    将以下用户要求改写为一段简短、明确、可执行的系统指令。
    只输出改写后的指令本身；不解释、不加标题、不虚构权限、不使用冗长角色扮演。
    保留用户明确要求的语言、格式和边界。限制在 1200 个字符内。
    """

    static var promptTemplate: String {
        let saved = UserDefaults.standard.string(forKey: promptKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? defaultPrompt : saved
    }

    static func setPromptTemplate(_ text: String) {
        UserDefaults.standard.set(String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000)),
                                  forKey: promptKey)
    }

    static func restoreDefaultPrompt() {
        UserDefaults.standard.removeObject(forKey: promptKey)
    }

    static func polish(requirements: String,
                       model: AIModelOption,
                       completion: @escaping (Result<String, Error>) -> Void) {
        let prompt = """
        \(promptTemplate)

        用户要求：
        \(String(requirements.prefix(6_000)))
        """
        APIClient.shared.complete(messages: [ChatMessage(role: .user, content: prompt)],
                                  model: model,
                                  maxTokens: 700) { result in
            completion(result.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_200)) })
        }
    }
}
