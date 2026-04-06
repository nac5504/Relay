import Foundation

@Observable
class BrowserAgent: Identifiable {
    var id: UUID
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
    var task: String = ""
    var taskTitle: String = ""  // AI-generated 3-5 word summary
    var tasks: [AgentTask] = []
    var relayStatus: RelayAgentStatus = .notStarted
    var chatMessages: [ChatMessage] = []
    var planMessages: [ChatMessage] = []
    var actionLog: [ActionEvent] = []
    var cost: Double = 0.0
    var sessionId: String = ""
    var waitingForInput: Bool = false
    var startedAt: Date?
    var planComplete: Bool = false
    var outputFiles: [String] = []
    var outputDir: String? = nil  // Absolute local path to the agent's output directory
    var planSteps: [PlanStep] = []
    var planRevisionCount: Int = 0
    var planVersion: Int = 0

    // Cursor overlay state — updated from WS "action" events
    var cursorPosition: CGPoint? = nil      // normalized 0…1
    var cursorActionType: String? = nil     // e.g. "left_click", "scroll", "type"
    var cursorVisible: Bool = false
    var cursorTimestamp: Date? = nil

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
        if !taskTitle.isEmpty { return taskTitle }
        return currentTask?.name ?? (task.isEmpty ? (tasks.last?.name ?? "Idle") : task)
    }

    var noVNCURL: URL? {
        guard noVNCPort > 0 else { return nil }
        return URL(string: "http://localhost:\(noVNCPort)/vnc_lite.html?autoconnect=true&scale=true")
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

    /// Messages for the current phase (plan or work)
    var activeMessages: [ChatMessage] {
        relayStatus.isPlanningPhase ? planMessages : chatMessages
    }

    init(id: UUID = UUID(), noVNCPort: Int = 0, vncPort: Int = 0, seleniumPort: Int = 0, displayName: String = "") {
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

    convenience init(from r: AgentResponse) {
        self.init(id: UUID(uuidString: r.id) ?? UUID(),
                  noVNCPort: r.noVNCPort ?? 0,
                  vncPort: r.vncPort ?? 0,
                  seleniumPort: 0,
                  displayName: r.agentName)
        self.agentName = r.agentName
        self.task = r.task
        self.sessionId = r.sessionId
        self.cost = r.cost
        self.waitingForInput = r.waitingForInput
        self.relayStatus = RelayAgentStatus(rawValue: r.status) ?? .starting
        self.startedAt = Date()
        if let err = r.error { self.errorMessage = err }
    }
}

enum AgentStatus: String {
    case starting
    case running
    case stopping
    case stopped
    case error
}

struct PlanStep: Identifiable, Equatable {
    let id: Int // stepNumber (1-indexed from backend)
    let shortDescription: String
    let detailedInstructions: String
    let suggestedTools: [String]
    var status: StepStatus = .pending

    enum StepStatus: String {
        case pending, active, completed, failed
    }

    var title: String { shortDescription }
    var isCompleted: Bool { status == .completed }
}
