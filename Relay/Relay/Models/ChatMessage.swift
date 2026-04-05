import Foundation
import SwiftUI

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: Role
    var text: String
    let timestamp: Date
    var agentName: String?
    var isLoading: Bool
    var isError: Bool

    enum Role: String, Codable {
        case user
        case assistant
        case system
        case action
        case thinking
        case output
    }

    enum ActionKind: String, Codable {
        case click, keyboard, bash, screenshot, editor, scroll, other

        var iconName: String {
            switch self {
            case .click:      return "cursorarrow.click.2"
            case .keyboard:   return "keyboard"
            case .bash:       return "terminal"
            case .screenshot: return "camera"
            case .editor:     return "pencil.line"
            case .scroll:     return "scroll"
            case .other:      return "gearshape"
            }
        }

        var tintColor: Color {
            switch self {
            case .click:      return .blue
            case .keyboard:   return .green
            case .bash:       return .purple
            case .screenshot: return .cyan
            case .editor:     return .orange
            case .scroll:     return .yellow
            case .other:      return .gray
            }
        }
    }

    /// The action kind inferred from description text
    var actionKind: ActionKind {
        let t = text.lowercased()
        if t.hasPrefix("ran:") || t.hasPrefix("restarted bash") { return .bash }
        if t.hasPrefix("typed") || t.hasPrefix("pressed") { return .keyboard }
        if t.hasPrefix("clicked") || t.hasPrefix("right-clicked") || t.hasPrefix("double-clicked")
            || t.hasPrefix("triple-clicked") || t.hasPrefix("dragged") || t.hasPrefix("moved mouse") { return .click }
        if t.hasPrefix("captured screenshot") { return .screenshot }
        if t.hasPrefix("scrolled") { return .scroll }
        if t.hasPrefix("view:") || t.hasPrefix("create:") || t.hasPrefix("str_replace:")
            || t.hasPrefix("insert:") || t.hasPrefix("undo_edit:") { return .editor }
        return .other
    }

    /// User-friendly display text for actions — strips coordinate noise
    var actionDisplayText: String {
        guard role == .action else { return text }
        var t = text
        // Strip " at (x, y)" from click/scroll actions
        if let range = t.range(of: #" at \(\d+,\s*\d+\)"#, options: .regularExpression) {
            t.removeSubrange(range)
        }
        // Strip "from (x, y) to (x, y)" from drag actions
        if let range = t.range(of: #" from \(\d+,\s*\d+\) to \(\d+,\s*\d+\)"#, options: .regularExpression) {
            t.removeSubrange(range)
        }
        // Strip " to (x, y)" from mouse_move
        if let range = t.range(of: #" to \(\d+,\s*\d+\)"#, options: .regularExpression) {
            t.removeSubrange(range)
        }
        // Clean up "Captured screenshot" → "Took screenshot"
        if t == "Captured screenshot" { t = "Took screenshot" }
        return t
    }

    init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = Date(), agentName: String? = nil, isLoading: Bool = false, isError: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.agentName = agentName
        self.isLoading = isLoading
        self.isError = isError
    }
}

// MARK: - Action Success/Failure Detection

enum ActionStatus {
    case success, failure, pending, neutral

    var dotColor: Color {
        switch self {
        case .success: return .green
        case .failure: return .red
        case .pending: return .white.opacity(0.3)
        case .neutral: return .white.opacity(0.15)
        }
    }
}

/// Determines action success/failure by looking at the next assistant message
func actionStatus(at index: Int, in messages: [ChatMessage]) -> ActionStatus {
    let msg = messages[index]
    guard msg.role == .action else { return .neutral }

    for j in (index + 1)..<messages.count {
        if messages[j].role == .assistant {
            let t = messages[j].text.lowercased()
            let failWords = ["didn't", "didn\u{2019}t", "failed", "error", "not ", "try again",
                             "doesn't", "doesn\u{2019}t", "couldn't", "couldn\u{2019}t",
                             "unable", "no context menu", "didn't work", "didn't open",
                             "didn't seem", "not working", "not appear"]
            if failWords.contains(where: { t.contains($0) }) {
                return .failure
            }
            return .success
        }
        if messages[j].role == .action {
            return .success // another action followed without complaint
        }
    }
    return .pending // still waiting for response
}
