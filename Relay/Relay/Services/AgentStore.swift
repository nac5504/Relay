import Foundation
import SwiftUI

protocol AgentStoreProtocol: AnyObject {
    var agents: [BrowserAgent] { get }
    func summonAgent(name: String?, task: String?) async throws
    func assignTask(to agent: BrowserAgent, task: String) async throws
    func deleteAgent(_ agent: BrowserAgent) async throws
    func sendMessage(to agent: BrowserAgent, text: String) async throws
}

@MainActor @Observable
class AgentStore: AgentStoreProtocol {
    var agents: [BrowserAgent] = []

    /// Messages in the main command chat (right side of home)
    var mainChatMessages: [ChatMessage] = []

    /// The agent currently being @mentioned in the chat input
    var mentionedAgentId: UUID?

    /// The agent currently focused/expanded in the grid
    var focusedAgentId: UUID?

    var focusedAgent: BrowserAgent? {
        guard let id = focusedAgentId else { return nil }
        return agents.first { $0.id == id }
    }

    private let backendBase = URL(string: "http://localhost:3001")!

    /// Focus on an agent and announce it in main chat
    func focusOnAgent(_ agent: BrowserAgent) {
        guard focusedAgentId != agent.id else { return }
        focusedAgentId = agent.id
        mainChatMessages.append(ChatMessage(role: .assistant, text: "Focused on **\(agent.agentName)**"))
    }

    /// Return to grid view and announce it in main chat
    func unfocus() {
        guard focusedAgentId != nil else { return }
        focusedAgentId = nil
        mainChatMessages.append(ChatMessage(role: .assistant, text: "Returned to grid view."))
    }

    private var didLoad = false

    init() {
        // Load existing agents from backend on startup
        Task { await loadAgentsOnce() }
    }

    private func loadAgentsOnce() async {
        guard !didLoad else { return }
        didLoad = true
        await loadAgents()
    }

    /// Update which agent is highlighted based on @mention in input text
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

    private let namePool = ["Atlas", "Nova", "Sage", "Echo", "Pixel", "Bolt", "Onyx", "Flux", "Haze", "Iris",
                              "Crux", "Vega", "Neon", "Apex", "Zinc", "Lumen", "Drift", "Prism", "Orbit", "Pulse"]

    /// Return a name not already used by a living agent. If the pool is exhausted, append a number.
    private func uniqueName(preferred: String? = nil) -> String {
        let taken = Set(agents.map { $0.agentName.lowercased() })

        if let preferred, !taken.contains(preferred.lowercased()) {
            return preferred
        }

        if let available = namePool.first(where: { !taken.contains($0.lowercased()) }) {
            return available
        }

        // Pool exhausted — generate numbered names
        var i = 1
        while true {
            let candidate = "Agent-\(i)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            i += 1
        }
    }

    // MARK: - Backend API

    /// Load existing agents from the backend on startup, or summon one if none exist
    private func loadAgents() async {
        // Wait for backend to be ready before querying
        await BackendProcess.shared.ensureReady()

        do {
            let url = backendBase.appendingPathComponent("agents")
            let (data, _) = try await URLSession.shared.data(from: url)
            let backendAgents = try JSONDecoder().decode([BackendAgent].self, from: data)
            for ba in backendAgents {
                if !agents.contains(where: { $0.containerID == ba.id }) {
                    let agent = ba.toBrowserAgent()
                    agents.append(agent)
                }
            }
        } catch {
            // Backend not ready yet — that's ok on first launch
        }

        // Auto-summon an agent if none exist
        if agents.isEmpty {
            try? await summonAgent(name: nil, task: nil)
        }
    }

    /// Create an agent via the backend. Blocks until container + browser are ready.
    private func createAgentViaBackend(name: String, task: String?) async throws -> BackendAgent {
        await BackendProcess.shared.ensureReady()

        var request = URLRequest(url: backendBase.appendingPathComponent("agents"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 60

        var body: [String: String] = ["agentName": name]
        if let task { body["task"] = task }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "Relay", code: status, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        return try JSONDecoder().decode(BackendAgent.self, from: data)
    }

    private func deleteAgentViaBackend(id: String) async throws {
        var request = URLRequest(url: backendBase.appendingPathComponent("agents/\(id)"))
        request.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Commands

    func summonAgent(name: String?, task: String?) async throws {
        mainChatMessages.append(ChatMessage(role: .user, text: "/summon"))

        let resolvedName = uniqueName(preferred: name)

        do {
            // Backend blocks until container is fully running + browser launched
            let ba = try await createAgentViaBackend(name: resolvedName, task: task)

            let tasks: [AgentTask] = task.map { [AgentTask(name: $0, status: .active, startedAt: Date())] } ?? []
            let agent = BrowserAgent(
                noVNCPort: ba.noVNCPort,
                vncPort: ba.vncPort,
                seleniumPort: 0,
                displayName: resolvedName
            )
            agent.agentName = resolvedName
            agent.tasks = tasks
            agent.relayStatus = task != nil ? .working : .waiting
            agent.status = .running
            agent.startedAt = Date()
            agent.cost = 0.0
            agent.containerID = ba.id
            agent.sessionId = ba.sessionId

            agents.append(agent)

            let reply = task != nil
                ? "Agent **\(resolvedName)** ready with task: \"\(task!)\""
                : "Agent **\(resolvedName)** ready."
            mainChatMessages.append(ChatMessage(role: .assistant, text: reply))
        } catch {
            mainChatMessages.append(ChatMessage(role: .assistant, text: "Failed to start agent: \(error.localizedDescription)"))
        }
    }

    func assignTask(to agent: BrowserAgent, task: String) async throws {
        agent.tasks.append(AgentTask(name: task, status: .pending))
        await chatWithAgent(agent, userText: "@\(agent.agentName) \(task)")
    }

    func deleteAgent(_ agent: BrowserAgent) async throws {
        if let backendId = agent.containerID {
            try? await deleteAgentViaBackend(id: backendId)
        }
        agents.removeAll { $0.id == agent.id }
    }

    func sendMessage(to agent: BrowserAgent, text: String) async throws {
        agent.chatMessages.append(ChatMessage(role: .user, text: text))
        agent.claudeHistory.append(.init(role: "user", content: text))

        let reply = ChatMessage(role: .assistant, text: "", agentName: agent.agentName, isLoading: true)
        agent.chatMessages.append(reply)

        let stream = try await ClaudeService.shared.stream(
            system: agent.systemPrompt,
            messages: agent.claudeHistory
        )

        guard let idx = agent.chatMessages.firstIndex(where: { $0.id == reply.id }) else { return }

        var fullResponse = ""
        for try await delta in stream {
            if agent.chatMessages[idx].isLoading { agent.chatMessages[idx].isLoading = false }
            for char in delta {
                fullResponse.append(char)
                agent.chatMessages[idx].text = fullResponse
                try? await Task.sleep(for: .milliseconds(12))
            }
        }

        if fullResponse.isEmpty { fullResponse = "No response" }
        agent.claudeHistory.append(.init(role: "assistant", content: fullResponse))
        agent.chatMessages[idx].text = fullResponse
        agent.cost += 0.02

        if agent.relayStatus == .waiting {
            agent.relayStatus = .working
            agent.waitingForInput = false
        }
    }

    /// Process a main chat input — handles /summon and @mentions
    func processMainChatInput(_ rawText: String) async throws {
        // Strip locked @AgentName prefix so /commands work while focused
        let text: String
        if let match = rawText.range(of: #"^@\w+\s+"#, options: .regularExpression) {
            let afterMention = String(rawText[match.upperBound...])
            text = afterMention.hasPrefix("/") ? afterMention : rawText
        } else {
            text = rawText
        }

        if text == "/focus" || text.hasPrefix("/focus ") {
            let remainder = text.dropFirst("/focus".count).trimmingCharacters(in: .whitespaces)
            mainChatMessages.append(ChatMessage(role: .user, text: text))
            if remainder.isEmpty {
                unfocus()
            } else {
                let name = remainder.hasPrefix("@") ? String(remainder.dropFirst()) : remainder
                if let agent = agents.first(where: { $0.agentName.lowercased() == name.lowercased() }) {
                    focusOnAgent(agent)
                } else {
                    mainChatMessages.append(ChatMessage(role: .assistant, text: "No agent found with name \"\(name)\"."))
                }
            }
        } else if text == "/summon" || text.hasPrefix("/summon ") {
            let remainder = text.dropFirst("/summon".count).trimmingCharacters(in: .whitespaces)
            let tokens = remainder.split(separator: " ", maxSplits: 1)
            let name: String? = tokens.first.map(String.init)
            let task: String? = tokens.count > 1 ? String(tokens[1]) : nil
            try await summonAgent(name: name, task: task)
        } else if text.hasPrefix("@") {
            let parts = text.dropFirst().split(separator: " ", maxSplits: 1)
            let name = parts.first.map(String.init) ?? ""
            if let agent = agents.first(where: { $0.agentName.lowercased() == name.lowercased() }) {
                await chatWithAgent(agent, userText: text)
            } else {
                mainChatMessages.append(ChatMessage(role: .user, text: text))
                mainChatMessages.append(ChatMessage(role: .assistant, text: "No agent found with name \"\(name)\". Use /summon \(name) <task> to create one."))
            }
        } else if let agent = focusedAgent {
            // While focused on an agent, plain messages go to that agent
            await chatWithAgent(agent, userText: text)
        } else {
            mainChatMessages.append(ChatMessage(role: .user, text: text))
            if agents.isEmpty {
                mainChatMessages.append(ChatMessage(role: .assistant, text: "No agents available. Use **/summon Name task** to create one."))
            } else {
                let names = agents.map { "@\($0.agentName)" }.joined(separator: ", ")
                mainChatMessages.append(ChatMessage(role: .assistant, text: "Tag an agent to send a message: \(names)"))
            }
        }
    }

    /// Send a message to an agent via Claude and append to main chat (streamed)
    private func chatWithAgent(_ agent: BrowserAgent, userText: String) async {
        mainChatMessages.append(ChatMessage(role: .user, text: userText))

        let loadingMsg = ChatMessage(role: .assistant, text: "", agentName: agent.agentName, isLoading: true)
        mainChatMessages.append(loadingMsg)

        // Strip the @AgentName prefix for the actual message to Claude
        let strippedText: String
        if userText.lowercased().hasPrefix("@\(agent.agentName.lowercased())") {
            strippedText = String(userText.dropFirst(agent.agentName.count + 1)).trimmingCharacters(in: .whitespaces)
        } else {
            strippedText = userText
        }
        let messageForClaude = strippedText.isEmpty ? "hello" : strippedText

        agent.claudeHistory.append(.init(role: "user", content: messageForClaude))

        do {
            let stream = try await ClaudeService.shared.stream(
                system: agent.systemPrompt,
                messages: agent.claudeHistory
            )

            guard let idx = mainChatMessages.firstIndex(where: { $0.id == loadingMsg.id }) else { return }

            var fullResponse = ""
            for try await delta in stream {
                if mainChatMessages[idx].isLoading { mainChatMessages[idx].isLoading = false }
                for char in delta {
                    fullResponse.append(char)
                    mainChatMessages[idx].text = fullResponse
                    try? await Task.sleep(for: .milliseconds(12))
                }
            }

            if fullResponse.isEmpty { fullResponse = "No response" }
            agent.claudeHistory.append(.init(role: "assistant", content: fullResponse))
            agent.cost += 0.02
            mainChatMessages[idx].text = fullResponse
        } catch {
            if let idx = mainChatMessages.firstIndex(where: { $0.id == loadingMsg.id }) {
                mainChatMessages[idx].text = "Error: \(error.localizedDescription)"
                mainChatMessages[idx].isLoading = false
            }
        }
    }

}

// MARK: - Backend JSON Decoding

/// Matches the JSON shape returned by POST/GET /agents
private struct BackendAgent: Decodable {
    let id: String
    let agentName: String
    let task: String
    let status: String
    let noVNCPort: Int
    let vncPort: Int
    let containerName: String
    let containerId: String?
    let cost: Double
    let startedAt: String
    let sessionId: String
    let error: String?

    func toBrowserAgent() -> BrowserAgent {
        let agent = BrowserAgent(
            noVNCPort: noVNCPort,
            vncPort: vncPort,
            seleniumPort: 0,
            displayName: agentName
        )
        agent.agentName = agentName
        agent.containerID = id
        agent.sessionId = sessionId
        agent.cost = cost
        agent.startedAt = ISO8601DateFormatter().date(from: startedAt)

        if !task.isEmpty {
            agent.tasks = [AgentTask(name: task, status: .active, startedAt: agent.startedAt ?? Date())]
        }

        switch status {
        case "running":
            agent.status = .running
            agent.relayStatus = task.isEmpty ? .waiting : .working
        case "starting":
            agent.status = .starting
            agent.relayStatus = .starting
        case "error":
            agent.status = .error
            agent.relayStatus = .error
            agent.errorMessage = error
        default:
            agent.status = .running
            agent.relayStatus = .waiting
        }

        return agent
    }
}
