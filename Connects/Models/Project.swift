import Foundation

struct Project: Codable, Equatable {
    let id: String
    var name: String
    var colorPreset: Int
    var updatedAt: Date
    var sortOrder: Int

    init(id: String = UUID().uuidString,
         name: String,
         colorPreset: Int = 0,
         updatedAt: Date = Date(),
         sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.colorPreset = colorPreset
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
    }
}
