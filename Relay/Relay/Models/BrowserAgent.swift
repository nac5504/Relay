import Foundation

@Observable
class BrowserAgent: Identifiable {
    let id: UUID
    var containerID: String?
    var status: AgentStatus = .starting
    var noVNCPort: Int
    var vncPort: Int
    var seleniumPort: Int
    var displayName: String
    var fps: Double = 0
    var errorMessage: String?

    // Relay agent management fields
    var agentName: String = ""
    var tasks: [AgentTask] = []
    var relayStatus: RelayAgentStatus = .notStarted
    var chatMessages: [ChatMessage] = []
    var actionLog: [ActionEvent] = []
    var cost: Double = 0.0
    var sessionId: String = ""
    var waitingForInput: Bool = false
    var startedAt: Date?

    // Claude agent conversation
    var claudeHistory: [ClaudeService.Message] = []
    var systemPrompt: String {
        let taskDesc = currentTaskName
        return """
        You are \(agentName), an AI agent in a multi-agent system called Relay. \
        You are currently working on: \(taskDesc). \
        Users interact with you via @\(agentName) mentions. \
        Keep responses concise (1-3 sentences). Be helpful and direct. \
        You can reference your current task status and ask clarifying questions.
        """
    }

    /// The task currently being worked on (first active, or first pending)
    var currentTask: AgentTask? {
        tasks.first(where: { $0.status == .active })
            ?? tasks.first(where: { $0.status == .pending })
    }

    /// Short description of what the agent is doing right now
    var currentTaskName: String {
        currentTask?.name ?? tasks.last?.name ?? "Idle"
    }

    var noVNCURL: URL {
        URL(string: "http://localhost:\(noVNCPort)/vnc.html?autoconnect=true&resize=scale&password=secret&view_only=false&reconnect=true&reconnect_delay=1000&host=localhost&port=\(noVNCPort)&path=websockify&encrypt=false")!
    }

    var formattedCost: String {
        String(format: "$%.2f", cost)
    }

    var elapsedTime: TimeInterval? {
        guard let start = startedAt else { return nil }
        return Date().timeIntervalSince(start)
    }

    var lastChatMessage: ChatMessage? {
        chatMessages.last
    }

    var avatarURL: URL? {
        guard !agentName.isEmpty else { return nil }
        let seed = agentName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? agentName
        return URL(string: "https://api.dicebear.com/9.x/bottts/png?seed=\(seed)&size=64")
    }

    init(id: UUID = UUID(), noVNCPort: Int, vncPort: Int, seleniumPort: Int, displayName: String) {
        self.id = id
        self.noVNCPort = noVNCPort
        self.vncPort = vncPort
        self.seleniumPort = seleniumPort
        self.displayName = displayName
    }

    convenience init(
        id: UUID = UUID(),
        agentName: String,
        tasks: [AgentTask],
        relayStatus: RelayAgentStatus,
        sessionId: String = UUID().uuidString
    ) {
        self.init(id: id, noVNCPort: 0, vncPort: 0, seleniumPort: 0, displayName: agentName)
        self.agentName = agentName
        self.tasks = tasks
        self.relayStatus = relayStatus
        self.sessionId = sessionId
    }
}

enum AgentStatus: String {
    case starting
    case running
    case stopping
    case stopped
    case error
}
