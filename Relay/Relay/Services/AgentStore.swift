import Foundation

@Observable
@MainActor
final class AgentStore {
    static let shared = AgentStore()
    private init() {}

    // MARK: - State

    var agents: [BrowserAgent] = []
    var focusedAgentId: UUID? = nil
    var isLoading = false

    // MARK: - Derived

    var focusedAgent: BrowserAgent? {
        agents.first { $0.id == focusedAgentId }
    }

    // MARK: - Lifecycle

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let responses = try await APIService.shared.fetchAgents()
            agents = responses.map { BrowserAgent(from: $0) }
        } catch {
            print("[AgentStore] Failed to load agents: \(error)")
        }
    }

    func createAgent(task: String, agentName: String? = nil) async throws {
        let response = try await APIService.shared.createAgent(task: task, agentName: agentName)
        let agent = BrowserAgent(from: response)
        agents.append(agent)
    }

    func deleteAgent(_ agent: BrowserAgent) async throws {
        try await APIService.shared.deleteAgent(id: agent.id.uuidString)
        agents.removeAll { $0.id == agent.id }
        if focusedAgentId == agent.id { focusedAgentId = nil }
    }

    func sendMessage(to agent: BrowserAgent, text: String) async throws {
        try await APIService.shared.sendMessage(agentId: agent.id.uuidString, text: text)
    }

    func focusOnAgent(_ id: UUID) {
        focusedAgentId = id
    }

    func unfocus() {
        focusedAgentId = nil
    }

    // MARK: - WebSocket mutations

    func updateAgent(id: String, mutation: (BrowserAgent) -> Void) {
        guard let agent = agents.first(where: { $0.id.uuidString == id }) else { return }
        mutation(agent)
    }

    func appendPlanMessage(agentId: String, role: String, text: String, streaming: Bool) {
        guard let agent = agents.first(where: { $0.id.uuidString == agentId }) else { return }

        if streaming, role == "assistant",
           let last = agent.planMessages.last, last.role == .assistant, !last.isLoading {
            // Append streaming delta to the last assistant message
            agent.planMessages[agent.planMessages.count - 1] = ChatMessage(
                id: last.id,
                role: .assistant,
                text: last.text + text,
                timestamp: last.timestamp
            )
        } else {
            let chatRole: ChatMessage.Role = role == "user" ? .user : .assistant
            agent.planMessages.append(ChatMessage(role: chatRole, text: text))
        }
    }

    func appendChatMessage(agentId: String, role: String, text: String) {
        guard let agent = agents.first(where: { $0.id.uuidString == agentId }) else { return }
        let chatRole: ChatMessage.Role
        let displayText: String

        switch role {
        case "user":
            chatRole = .user
            displayText = text
        case "thinking":
            chatRole = .system
            displayText = "Thinking: \(text)"
        case "action":
            chatRole = .system
            displayText = text
        default:
            chatRole = .assistant
            displayText = text
        }

        agent.chatMessages.append(ChatMessage(role: chatRole, text: displayText))
    }

    func upsertAgentFromJSON(_ json: [String: Any]) {
        guard let idStr = json["id"] as? String,
              let uuid = UUID(uuidString: idStr) else { return }

        if agents.first(where: { $0.id == uuid }) != nil { return }

        let response = AgentResponse(
            id: idStr,
            agentName: json["agentName"] as? String ?? "Agent",
            task: json["task"] as? String ?? "",
            status: json["status"] as? String ?? "starting",
            noVNCPort: json["noVNCPort"] as? Int,
            vncPort: json["vncPort"] as? Int,
            sessionId: json["sessionId"] as? String ?? "",
            cost: json["cost"] as? Double ?? 0,
            waitingForInput: json["waitingForInput"] as? Bool ?? false,
            containerReady: json["containerReady"] as? Bool ?? false,
            error: json["error"] as? String
        )
        agents.append(BrowserAgent(from: response))
    }

    func removeAgent(id: String) {
        agents.removeAll { $0.id.uuidString == id }
        if focusedAgentId?.uuidString == id { focusedAgentId = nil }
    }
}
