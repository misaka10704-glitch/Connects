import XCTest
@testable import Connects

final class MemoryAgentLogicTests: XCTestCase {
    func testAgentPromptIsTrimmedToContextCap() {
        let agent = CustomAgent(name: "测试", userRequirements: "", polishedPrompt: String(repeating: "x", count: 3_000))
        XCTAssertEqual(agent.trimmedPrompt.count, 2_400)
    }

    func testAgentAppearanceHasTwentyDistinctPresets() {
        XCTAssertEqual(AgentAppearancePreset.all.count, 20)
        XCTAssertEqual(Set(AgentAppearancePreset.all.map(\.index)).count, 20)
    }

    func testLegacyAgentDecodesWithDefaultAppearance() throws {
        let json = """
        {"id":"legacy","name":"旧智能体","userRequirements":"","polishedPrompt":"prompt","isEnabled":true,"updatedAt":0}
        """
        let agent = try JSONDecoder().decode(CustomAgent.self, from: Data(json.utf8))
        XCTAssertEqual(agent.iconPreset, 0)
    }

    func testMemoryPromptDefaultsAreAvailable() {
        for kind in MemoryPromptKind.allCases {
            XCTAssertFalse(kind.defaultValue.isEmpty)
            XCTAssertFalse(kind.title.isEmpty)
        }
    }

    func testContextBuilderKeepsAgentAndMemorySeparateSystemMessages() {
        let result = ContextBuilder.build(
            from: [ChatMessage(role: .user, content: "你好")],
            model: .deepseekV4Flash,
            agentPrompt: "使用简洁中文。",
            memoryBackground: "用户偏好简洁回答。"
        )
        let systems = result.messages.filter { $0.role == .system }.map(\.content)
        XCTAssertTrue(systems.contains { $0.contains("[Cross-session user memory]") })
        XCTAssertTrue(systems.contains { $0.contains("[Selected user agent]") })
    }

    func testMemoryCaptureDefaultsDiscourageVerboseDumps() {
        XCTAssertTrue(MemoryPromptKind.capture.defaultValue.contains("≤80字"))
        XCTAssertTrue(MemoryPromptKind.compaction.defaultValue.contains("## 事件索引"))
        XCTAssertTrue(MemoryPromptKind.injection.defaultValue.contains("会话链接"))
    }
}
