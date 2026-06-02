import Foundation

struct AIPresetChatMessage: Identifiable, Codable, Hashable, Sendable {
    enum Role: String, Codable, Hashable, Sendable {
        case user
        case assistant
        case system
    }

    let id: UUID
    var role: Role
    var markdown: String
    var createdAt: Date

    /// Optional: a proposed updated settings snapshot from the assistant.
    var proposedSettings: EQSettings?

    /// Optional: the preset settings the assistant edited from, used for stable diff display after applying.
    var baseSettings: EQSettings?

    /// Optional: a proposed preset name (rename/duplicate actions).
    var proposedPresetName: String?

    /// Optional: the assistant's declared action.
    var proposedActionRaw: String?

    init(
        id: UUID = UUID(),
        role: Role,
        markdown: String,
        createdAt: Date = Date(),
        proposedSettings: EQSettings? = nil,
        baseSettings: EQSettings? = nil,
        proposedPresetName: String? = nil,
        proposedActionRaw: String? = nil
    ) {
        self.id = id
        self.role = role
        self.markdown = markdown
        self.createdAt = createdAt
        self.proposedSettings = proposedSettings
        self.baseSettings = baseSettings
        self.proposedPresetName = proposedPresetName
        self.proposedActionRaw = proposedActionRaw
    }
}
