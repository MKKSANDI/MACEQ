import Foundation

enum EQPresetOrigin: String, Codable, Hashable {
    case user
    case ai
}

struct EQPreset: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var settings: EQSettings
    var createdAt: Date
    var updatedAt: Date
    var origin: EQPresetOrigin
    var chatHistory: [AIPresetChatMessage]

    init(
        id: UUID = UUID(),
        name: String,
        settings: EQSettings,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        origin: EQPresetOrigin = .user,
        chatHistory: [AIPresetChatMessage] = []
    ) {
        self.id = id
        self.name = name
        self.settings = settings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.origin = origin
        self.chatHistory = chatHistory
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case settings
        case createdAt
        case updatedAt
        case origin
        case chatHistory
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        settings = try c.decode(EQSettings.self, forKey: .settings)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        origin = try c.decodeIfPresent(EQPresetOrigin.self, forKey: .origin) ?? .user
        chatHistory = try c.decodeIfPresent([AIPresetChatMessage].self, forKey: .chatHistory) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(settings, forKey: .settings)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(origin, forKey: .origin)
        try c.encode(chatHistory, forKey: .chatHistory)
    }
}
