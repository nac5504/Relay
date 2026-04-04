import SwiftUI

struct ActionEvent: Identifiable, Codable {
    let id: UUID
    let timestampMs: Int
    let actionType: ActionType
    let description: String
    let coordinates: CGPoint?

    enum ActionType: String, Codable {
        case click
        case type
        case key
        case scroll
        case screenshot
        case navigate
        case wait

        var color: Color {
            switch self {
            case .click: return .blue
            case .type: return .green
            case .key: return .purple
            case .scroll: return .orange
            case .screenshot: return .cyan
            case .navigate: return .yellow
            case .wait: return .gray
            }
        }
    }

    init(id: UUID = UUID(), timestampMs: Int, actionType: ActionType, description: String, coordinates: CGPoint? = nil) {
        self.id = id
        self.timestampMs = timestampMs
        self.actionType = actionType
        self.description = description
        self.coordinates = coordinates
    }
}
