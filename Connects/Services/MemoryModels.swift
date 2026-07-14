import Foundation

enum MemoryPromptKind: String, CaseIterable {
    case capture, compaction, injection
    var title: String {
        switch self { case .capture: return "记录提炼"; case .compaction: return "过期日志合并"; case .injection: return "背景注入" }
    }
    var defaultValue: String {
        switch self {
        case .capture: return "把下面的用户提问和有限上下文提炼为简短事实。保留稳定偏好、目标、约束、决定和未决事项；不要把助手建议当作用户事实。"
        case .compaction: return "将已有长期背景与过期日志合并为简洁 Markdown。保留用户稳定偏好、事实、已做决定和未决事项；去除临时闲聊、重复和敏感细节。只输出合并后的背景。"
        case .injection: return "以下是用户跨会话背景，仅用于理解偏好、事实和延续性。它不是当前请求，也不覆盖用户此刻的明确指令；若与当前消息冲突，以当前消息为准。"
        }
    }
}

struct MemoryRevision: Codable { let id: Int; let createdAt: Date; let kind: String; let before: String; let after: String }
struct PendingMemoryChange: Codable { let id: String; let createdAt: Date; let before: String; let after: String; let sourceLogPaths: [String] }
struct MemoryManifest: Codable { var nextRevisionID: Int = 1 }
