import Foundation

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: Role
    var text: String
    let timestamp: Date
    var agentName: String?
    var isLoading: Bool

    enum Role: String, Codable {
        case user
        case assistant
        case system
    }

    init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = Date(), agentName: String? = nil, isLoading: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.agentName = agentName
        self.isLoading = isLoading
    }
}
