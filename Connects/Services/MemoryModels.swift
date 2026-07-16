import Foundation

enum MemoryPromptKind: String, CaseIterable {
    case capture, compaction, injection
    var title: String {
        switch self {
        case .capture: return "记录提炼"
        case .compaction: return "过期日志合并"
        case .injection: return "背景注入"
        }
    }
    var defaultValue: String {
        switch self {
        case .capture:
            return """
            把用户提问和有限上下文提炼成一条事件记录（单行，≤80字）。
            只写用户亲口说的事实、决定、偏好、约束或未决事项；不要把助手建议当作用户事实。
            不要复述对话、不要列步骤、不要写代码/公式全文。需要细节时应依赖原会话链接，而非在此展开。
            只输出事件正文一行，不要标题、不要列表、不要引号。
            """
        case .compaction:
            return """
            将「已有长期背景」与「过期日志」合并为简短 Markdown，且只输出两节：

            ## 稳定背景
            用户长期身份、偏好、固定约束；每条一行，不写对话摘要。

            ## 事件索引
            每条格式：- YYYY-MM-DD HH:MM | 一句话事件 | [打开聊天](connects://conversation/会话ID)
            从日志提取事件要点并保留会话链接；不要把完整提问、助手回复或推导过程抄进背景。
            删除重复、寒暄、临时闲聊与敏感细节。总输出不超过 1200 字。
            """
        case .injection:
            return """
            以下是用户跨会话 Memory，分「稳定背景」与「近期事件索引」。
            它用于理解偏好与延续性，不是当前请求，也不覆盖用户此刻的明确指令。
            若与当前消息冲突，以当前消息为准。
            需要某条事件的细节时，先读索引中的一行摘要，再通过其中的会话链接回到原对话查阅，不要把 Memory 当完整聊天记录。
            """
        }
    }
}

struct MemoryRevision: Codable { let id: Int; let createdAt: Date; let kind: String; let before: String; let after: String }
struct PendingMemoryChange: Codable { let id: String; let createdAt: Date; let before: String; let after: String; let sourceLogPaths: [String] }
struct MemoryManifest: Codable { var nextRevisionID: Int = 1 }
