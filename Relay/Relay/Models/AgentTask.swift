import Foundation

struct AgentTask: Identifiable, Equatable {
    let id: UUID
    var name: String
    var status: TaskStatus
    var startedAt: Date?
    var completedAt: Date?

    enum TaskStatus: String, Codable {
        case pending
        case active
        case completed
        case failed
    }

    init(id: UUID = UUID(), name: String, status: TaskStatus = .pending, startedAt: Date? = nil, completedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}
