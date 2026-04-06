import SwiftUI

enum RelayAgentStatus: String, Codable, CaseIterable {
    case notStarted
    case starting
    case planning   // container ready, plan agent conversing
    case working
    case waiting
    case paused     // plan execution paused via /stop — resumable
    case completed
    case error
    case stopped

    var displayName: String {
        switch self {
        case .notStarted: return "Not Started"
        case .starting: return "Starting..."
        case .planning: return "Planning"
        case .working: return "Working"
        case .waiting: return "Waiting for Input"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .error: return "Error"
        case .stopped: return "Stopped"
        }
    }

    var dotColor: Color {
        switch self {
        case .working: return .green
        case .planning: return .yellow
        case .waiting: return .yellow
        case .paused: return .orange
        case .starting: return .blue
        case .completed: return .blue
        case .error: return .red
        case .stopped: return .gray
        case .notStarted: return .yellow
        }
    }

    var iconName: String {
        switch self {
        case .working: return "circle.fill"
        case .planning: return "text.bubble.fill"
        case .waiting: return "questionmark.circle.fill"
        case .paused: return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .starting: return "arrow.clockwise.circle.fill"
        case .stopped: return "stop.circle.fill"
        case .notStarted: return "circle.dashed"
        }
    }

    var sidebarLabel: String {
        switch self {
        case .notStarted: return "Idle"
        case .starting:   return "Starting"
        case .planning:   return "Planning"
        case .working:    return "Acting"
        case .waiting:    return "Waiting"
        case .paused:     return "Paused"
        case .completed:  return "Done"
        case .error:      return "Error"
        case .stopped:    return "Stopped"
        }
    }

    var isPlanningPhase: Bool {
        self == .starting || self == .planning
    }
}
