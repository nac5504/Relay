import SwiftUI

enum RelayAgentStatus: String, Codable, CaseIterable {
    case notStarted
    case starting
    case working
    case waiting
    case completed
    case error
    case stopped

    var displayName: String {
        switch self {
        case .notStarted: return "Not Started"
        case .starting: return "Starting"
        case .working: return "Working"
        case .waiting: return "Waiting for Input"
        case .completed: return "Completed"
        case .error: return "Error"
        case .stopped: return "Stopped"
        }
    }

    var dotColor: Color {
        switch self {
        case .working: return .green
        case .waiting: return .orange
        case .starting: return .yellow
        case .completed: return .blue
        case .error: return .red
        case .stopped: return .gray
        case .notStarted: return .gray.opacity(0.5)
        }
    }

    var iconName: String {
        switch self {
        case .working: return "circle.fill"
        case .waiting: return "questionmark.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .starting: return "arrow.clockwise.circle.fill"
        case .stopped: return "stop.circle.fill"
        case .notStarted: return "circle.dashed"
        }
    }
}
