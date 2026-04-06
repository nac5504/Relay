import Foundation
import SwiftUI

@Observable
@MainActor
final class AgentStore {
    static let shared = AgentStore()
    private init() {}

    // MARK: - State

    var agents: [BrowserAgent] = []
    var focusedAgentId: UUID? = nil
    var mentionedAgentId: UUID? = nil
    var mainChatMessages: [ChatMessage] = []
    var isLoading = false

    // MARK: - Derived

    var focusedAgent: BrowserAgent? {
        agents.first { $0.id == focusedAgentId }
    }

    /// Messages filtered to the focused agent, or all messages if no agent is focused
    var filteredMainChatMessages: [ChatMessage] {
        guard let agent = focusedAgent else { return mainChatMessages }
        return mainChatMessages.filter { $0.agentName == agent.agentName }
    }

    // MARK: - Lifecycle

    func load() async {
        isLoading = true
        defer { isLoading = false }

        // Push saved API key to backend before doing anything
        let savedKey = UserDefaults.standard.string(forKey: "anthropic_api_key") ?? ""
        if !savedKey.isEmpty {
            try? await APIService.shared.setApiKey(savedKey)
        }

        do {
            let responses = try await APIService.shared.fetchAgents()
            agents = responses.map { BrowserAgent(from: $0) }
        } catch {
            print("[AgentStore] Failed to load agents: \(error)")
        }

        // Always summon a fresh agent on launch
        if !savedKey.isEmpty {
            do {
                try await createAgent(task: nil)
            } catch {
                print("[AgentStore] Failed to auto-create agent: \(error)")
            }
        }
    }

    func createAgent(task: String? = nil, agentName: String? = nil) async throws {
        let response = try await APIService.shared.createAgent(task: task, agentName: agentName)
        let agent = BrowserAgent(from: response)
        // WS agent_added may have already added it
        if !agents.contains(where: { $0.id == agent.id }) {
            agents.append(agent)
        }
        // Stay on grid view — don't auto-focus the new agent
        mainChatMessages.append(ChatMessage(role: .assistant, text: "Spawning agent **\(agent.agentName)** — planning your task..."))
    }

    func deleteAgent(_ agent: BrowserAgent) async throws {
        try await APIService.shared.deleteAgent(id: agent.id.uuidString)
        agents.removeAll { $0.id == agent.id }
        if focusedAgentId == agent.id { focusedAgentId = nil }
    }

    func sendMessage(to agent: BrowserAgent, text: String) async throws {
        try await APIService.shared.sendMessage(agentId: agent.id.uuidString, text: text)
    }

    func pauseAgent(_ agent: BrowserAgent) async throws {
        try await APIService.shared.pauseAgent(id: agent.id.uuidString)
        agent.relayStatus = .paused
    }

    func resumeAgent(_ agent: BrowserAgent) async throws {
        try await APIService.shared.resumeAgent(id: agent.id.uuidString)
        agent.relayStatus = .working
    }

    // MARK: - Navigation

    func focusOnAgent(_ agent: BrowserAgent) {
        guard focusedAgentId != agent.id else { return }
        focusedAgentId = agent.id
    }

    func unfocus() {
        focusedAgentId = nil
    }

    func updateMentionedAgent(from text: String) {
        guard let atRange = text.range(of: "@"),
              atRange.lowerBound < text.endIndex else {
            mentionedAgentId = nil
            return
        }
        let afterAt = String(text[atRange.upperBound...])
        let name = String(afterAt.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
        guard !name.isEmpty else {
            mentionedAgentId = nil
            return
        }
        mentionedAgentId = agents.first(where: { $0.agentName.lowercased() == name.lowercased() })?.id
    }

    // MARK: - Main chat commands

    func processMainChatInput(_ rawText: String) async throws {
        let text = rawText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        if text.hasPrefix("/summon") {
            let remainder = text.dropFirst("/summon".count).trimmingCharacters(in: .whitespaces)
            let tokens = remainder.split(separator: " ", maxSplits: 1)
            let name: String? = tokens.isEmpty ? nil : String(tokens[0])
            let task: String? = tokens.count > 1 ? String(tokens[1]) : nil
            mainChatMessages.append(ChatMessage(role: .user, text: text))
            try await createAgent(task: task, agentName: name)
        } else if text.hasPrefix("/stop") {
            // /stop pauses the plan execution (agent + container stay alive — use /resume to continue)
            let targetName = text.dropFirst("/stop".count)
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "@", with: "")
            mainChatMessages.append(ChatMessage(role: .user, text: text))

            let target: BrowserAgent?
            if !targetName.isEmpty {
                target = agents.first(where: { $0.agentName.lowercased() == targetName.lowercased() })
                if target == nil {
                    mainChatMessages.append(ChatMessage(role: .assistant, text: "No agent named \"\(targetName)\"."))
                    return
                }
            } else {
                target = focusedAgent ?? agents.first(where: { $0.relayStatus == .working || $0.relayStatus == .waiting }) ?? agents.last
            }

            guard let agent = target else {
                mainChatMessages.append(ChatMessage(role: .assistant, text: "No agents to pause."))
                return
            }

            let name = agent.agentName
            switch agent.relayStatus {
            case .working, .waiting:
                do {
                    try await pauseAgent(agent)
                    mainChatMessages.append(ChatMessage(role: .assistant, text: "Paused **\(name)**. Use `/resume \(name)` or send a new message to continue."))
                } catch {
                    mainChatMessages.append(ChatMessage(role: .assistant, text: "Failed to pause **\(name)**: \(error.localizedDescription)"))
                }
            case .paused:
                mainChatMessages.append(ChatMessage(role: .assistant, text: "**\(name)** is already paused."))
            case .starting, .planning:
                mainChatMessages.append(ChatMessage(role: .assistant, text: "**\(name)** is still planning — nothing to pause yet."))
            case .completed, .stopped, .error, .notStarted:
                mainChatMessages.append(ChatMessage(role: .assistant, text: "**\(name)** is not running (\(agent.relayStatus.displayName))."))
            }
        } else if text.hasPrefix("/resume") {
            let targetName = text.dropFirst("/resume".count)
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "@", with: "")
            mainChatMessages.append(ChatMessage(role: .user, text: text))

            let target: BrowserAgent?
            if !targetName.isEmpty {
                target = agents.first(where: { $0.agentName.lowercased() == targetName.lowercased() })
                if target == nil {
                    mainChatMessages.append(ChatMessage(role: .assistant, text: "No agent named \"\(targetName)\"."))
                    return
                }
            } else {
                target = focusedAgent ?? agents.first(where: { $0.relayStatus == .paused }) ?? agents.last
            }

            guard let agent = target else {
                mainChatMessages.append(ChatMessage(role: .assistant, text: "No agents to resume."))
                return
            }

            guard agent.relayStatus == .paused else {
                mainChatMessages.append(ChatMessage(role: .assistant, text: "**\(agent.agentName)** is not paused (\(agent.relayStatus.displayName))."))
                return
            }

            do {
                try await resumeAgent(agent)
                mainChatMessages.append(ChatMessage(role: .assistant, text: "Resumed **\(agent.agentName)**."))
            } catch {
                mainChatMessages.append(ChatMessage(role: .assistant, text: "Failed to resume **\(agent.agentName)**: \(error.localizedDescription)"))
            }
        } else if text.hasPrefix("/focus") {
            let targetName = text.dropFirst("/focus".count)
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "@", with: "")
            mainChatMessages.append(ChatMessage(role: .user, text: text))
            if let agent = agents.first(where: { $0.agentName.lowercased() == targetName.lowercased() }) {
                focusOnAgent(agent)
                mainChatMessages.append(ChatMessage(role: .assistant, text: "Focused on **\(agent.agentName)**."))
            } else if !targetName.isEmpty {
                mainChatMessages.append(ChatMessage(role: .assistant, text: "No agent named \"\(targetName)\". Available: \(agents.map { "@\($0.agentName)" }.joined(separator: ", "))"))
            } else {
                // No target — unfocus back to grid
                unfocus()
                mainChatMessages.append(ChatMessage(role: .assistant, text: "Back to grid view."))
            }
        } else if text.hasPrefix("@") {
            // @mention takes priority over focused/planning agent
            let parts = text.dropFirst().split(separator: " ", maxSplits: 1)
            let name = parts.first.map(String.init) ?? ""
            let message = parts.count > 1 ? String(parts[1]) : ""
            if let agent = agents.first(where: { $0.agentName.lowercased() == name.lowercased() }) {
                mainChatMessages.append(ChatMessage(role: .user, text: text, agentName: agent.agentName))
                if !message.isEmpty {
                    try await sendMessage(to: agent, text: message)
                }
            } else {
                mainChatMessages.append(ChatMessage(role: .user, text: text))
                mainChatMessages.append(ChatMessage(role: .assistant, text: "No agent named \"\(name)\". Use /summon \(name) <task>"))
            }
        } else if let agent = focusedAgent {
            // Focused agent — route to it
            mainChatMessages.append(ChatMessage(role: .user, text: text, agentName: agent.agentName))
            try await sendMessage(to: agent, text: text)
        } else if let planningAgent = agents.first(where: { $0.relayStatus.isPlanningPhase }) {
            // Planning agent fallback
            mainChatMessages.append(ChatMessage(role: .user, text: text, agentName: planningAgent.agentName))
            try await sendMessage(to: planningAgent, text: text)
        } else {
            mainChatMessages.append(ChatMessage(role: .user, text: text))
            if agents.isEmpty {
                mainChatMessages.append(ChatMessage(role: .assistant, text: "No agents. Use **/summon Name task** to create one."))
            } else {
                let names = agents.map { "@\($0.agentName)" }.joined(separator: ", ")
                mainChatMessages.append(ChatMessage(role: .assistant, text: "Tag an agent: \(names)"))
            }
        }
    }

    // MARK: - WebSocket mutations

    private func findAgent(id: String) -> BrowserAgent? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return agents.first(where: { $0.id == uuid })
    }

    func updateAgent(id: String, mutation: (BrowserAgent) -> Void) {
        guard let agent = findAgent(id: id) else { return }
        mutation(agent)
    }

    func appendPlanMessage(agentId: String, role: String, text: String, streaming: Bool) {
        guard let agent = findAgent(id: agentId) else { return }

        if streaming, role == "assistant",
           let last = agent.planMessages.last, last.role == .assistant, !last.isLoading {
            let updated = ChatMessage(
                id: last.id,
                role: .assistant,
                text: last.text + text,
                timestamp: last.timestamp,
                agentName: agent.agentName
            )
            agent.planMessages[agent.planMessages.count - 1] = updated
            if let mainIdx = mainChatMessages.lastIndex(where: { $0.id == last.id }) {
                mainChatMessages[mainIdx] = updated
            }
        } else {
            let chatRole: ChatMessage.Role = role == "user" ? .user : .assistant
            let msg = ChatMessage(role: chatRole, text: text, agentName: role == "assistant" ? agent.agentName : nil)
            agent.planMessages.append(msg)
            if role != "user" {
                mainChatMessages.append(msg)
            }
        }
    }

    func handlePlanUpdate(agentId: String, steps: [PlanStep], version: Int) {
        guard let agent = findAgent(id: agentId) else { return }

        // Mark previous .plan messages as .planRevised
        for i in agent.planMessages.indices {
            if agent.planMessages[i].role == .plan {
                let old = agent.planMessages[i]
                agent.planMessages[i] = ChatMessage(
                    id: old.id, role: .planRevised, text: old.text,
                    timestamp: old.timestamp, agentName: old.agentName
                )
            }
        }
        for i in mainChatMessages.indices {
            if mainChatMessages[i].role == .plan && mainChatMessages[i].agentName == agent.agentName {
                let old = mainChatMessages[i]
                mainChatMessages[i] = ChatMessage(
                    id: old.id, role: .planRevised, text: old.text,
                    timestamp: old.timestamp, agentName: old.agentName
                )
            }
        }

        // Insert new .plan message
        let planMsg = ChatMessage(role: .plan, text: "", agentName: agent.agentName)
        agent.planMessages.append(planMsg)
        mainChatMessages.append(planMsg)

        // Update plan data
        agent.planSteps = steps
        if version > agent.planVersion {
            agent.planRevisionCount += 1
        }
        agent.planVersion = version
    }

    func appendChatMessage(agentId: String, role: String, text: String) {
        guard let agent = findAgent(id: agentId) else {
            print("[AgentStore] appendChatMessage: agent \(agentId) NOT FOUND — dropping \(role): \(text.prefix(60))")
            return
        }
        print("[AgentStore] appendChatMessage: agent=\(agent.agentName) role=\(role) text=\(text.prefix(60))")
        let chatRole: ChatMessage.Role
        let displayText: String

        switch role {
        case "user":
            chatRole = .user
            displayText = text
        case "thinking":
            chatRole = .thinking
            displayText = text
        case "action":
            chatRole = .action
            displayText = text
        case "output":
            chatRole = .output
            displayText = text
        default:
            chatRole = .assistant
            displayText = text
        }

        let msg = ChatMessage(role: chatRole, text: displayText, agentName: role != "user" ? agent.agentName : nil)
        agent.chatMessages.append(msg)
        // Mirror to main chat so user sees agent progress in the right panel
        if role != "user" {
            mainChatMessages.append(msg)
        }
    }

    func updateAgentCursor(agentId: String, x: Double, y: Double, screenWidth: Double, screenHeight: Double, actionType: String) {
        guard let agent = findAgent(id: agentId) else { return }
        let normalized = CGPoint(x: x / screenWidth, y: y / screenHeight)
        agent.cursorPosition = normalized
        agent.cursorActionType = actionType
        agent.cursorVisible = true
        agent.cursorTimestamp = Date()

        // Auto-hide cursor after 3 seconds of no activity
        let ts = agent.cursorTimestamp
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak agent] in
            guard let agent, agent.cursorTimestamp == ts else { return }
            withAnimation(.easeOut(duration: 0.5)) {
                agent.cursorVisible = false
            }
        }
    }

    func appendErrorMessage(agentId: String, text: String) {
        guard let agent = findAgent(id: agentId) else { return }
        let msg = ChatMessage(role: .system, text: text, agentName: agent.agentName, isError: true)
        agent.chatMessages.append(msg)
        mainChatMessages.append(msg)
    }

    func upsertAgentFromJSON(_ json: [String: Any]) {
        guard let idStr = json["id"] as? String,
              let uuid = UUID(uuidString: idStr) else { return }

        // Already exists (createAgent response may have added it before the WS event)
        if agents.contains(where: { $0.id == uuid }) { return }

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
        guard let uuid = UUID(uuidString: id) else { return }
        agents.removeAll { $0.id == uuid }
        if focusedAgentId == uuid { focusedAgentId = nil }
    }
}
