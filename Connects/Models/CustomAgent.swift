import Foundation

struct CustomAgent: Codable, Equatable {
    let id: String
    var name: String
    var userRequirements: String
    var polishedPrompt: String
    var isEnabled: Bool
    var updatedAt: Date
    var iconPreset: Int

    init(id: String = UUID().uuidString,
         name: String,
         userRequirements: String,
         polishedPrompt: String,
         isEnabled: Bool = true,
         updatedAt: Date = Date(),
         iconPreset: Int = 0) {
        self.id = id
        self.name = name
        self.userRequirements = userRequirements
        self.polishedPrompt = polishedPrompt
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
        self.iconPreset = iconPreset
    }

    var trimmedPrompt: String {
        String(polishedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_400))
    }

    enum CodingKeys: String, CodingKey { case id, name, userRequirements, polishedPrompt, isEnabled, updatedAt, iconPreset }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        userRequirements = try c.decode(String.self, forKey: .userRequirements)
        polishedPrompt = try c.decode(String.self, forKey: .polishedPrompt)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        iconPreset = try c.decodeIfPresent(Int.self, forKey: .iconPreset) ?? 0
    }
}
