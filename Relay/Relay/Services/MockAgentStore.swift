import Foundation
import SwiftUI

protocol AgentStoreProtocol: AnyObject {
    var agents: [BrowserAgent] { get }
    func summonAgent(name: String, task: String?) async throws
    func assignTask(to agent: BrowserAgent, task: String) async throws
    func deleteAgent(_ agent: BrowserAgent) async throws
    func sendMessage(to agent: BrowserAgent, text: String) async throws
}

@MainActor @Observable
class MockAgentStore: AgentStoreProtocol {
    var agents: [BrowserAgent] = []

    /// Messages in the main command chat (right side of home)
    var mainChatMessages: [ChatMessage] = []

    /// The agent currently being @mentioned in the chat input
    var mentionedAgentId: UUID?

    init() {
        let names = ["Atlas", "Nova", "Sage", "Echo", "Pixel"]
        let name = names.randomElement()!
        let agent = BrowserAgent(
            agentName: name,
            tasks: [],
            relayStatus: .waiting
        )
        agent.status = .running
        agent.startedAt = Date()
        agent.cost = 0.0
        agent.waitingForInput = true
        agents = [agent]
        mainChatMessages = []
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

    // MARK: - Commands

    func summonAgent(name: String, task: String?) async throws {
        let displayCmd = task != nil ? "/summon \(name) \(task!)" : "/summon \(name)"
        mainChatMessages.append(ChatMessage(role: .user, text: displayCmd))

        try await Task.sleep(for: .milliseconds(800))

        let tasks: [AgentTask] = task.map { [AgentTask(name: $0, status: .active, startedAt: Date())] } ?? []
        let agent = BrowserAgent(
            agentName: name,
            tasks: tasks,
            relayStatus: task != nil ? .starting : .waiting
        )
        agent.startedAt = Date()
        agent.cost = 0.0
        agents.append(agent)

        let reply: String
        if let task {
            reply = "Spawning agent **\(name)** with task: \"\(task)\""
        } else {
            reply = "Spawning agent **\(name)** — standing by for tasks."
        }
        mainChatMessages.append(ChatMessage(role: .assistant, text: reply))

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if task != nil {
                agent.relayStatus = .working
            }
            agent.status = .running
        }
    }

    func assignTask(to agent: BrowserAgent, task: String) async throws {
        agent.tasks.append(AgentTask(name: task, status: .pending))
        await chatWithAgent(agent, userText: "@\(agent.agentName) \(task)")
    }

    func deleteAgent(_ agent: BrowserAgent) async throws {
        agents.removeAll { $0.id == agent.id }
    }

    func sendMessage(to agent: BrowserAgent, text: String) async throws {
        let userMsg = ChatMessage(role: .user, text: text)
        agent.chatMessages.append(userMsg)

        agent.claudeHistory.append(.init(role: "user", content: text))
        let response = try await ClaudeService.shared.send(
            system: agent.systemPrompt,
            messages: agent.claudeHistory
        )
        agent.claudeHistory.append(.init(role: "assistant", content: response))

        let reply = ChatMessage(role: .assistant, text: response, agentName: agent.agentName)
        agent.chatMessages.append(reply)
        agent.cost += 0.02

        if agent.relayStatus == .waiting {
            agent.relayStatus = .working
            agent.waitingForInput = false
        }
    }

    /// Process a main chat input — handles /summon and @mentions
    func processMainChatInput(_ text: String) async throws {
        if text == "/summon" || text.hasPrefix("/summon ") {
            let remainder = text.dropFirst("/summon".count).trimmingCharacters(in: .whitespaces)
            let tokens = remainder.split(separator: " ", maxSplits: 1)
            let names = ["Atlas", "Nova", "Sage", "Echo", "Pixel", "Bolt", "Onyx", "Flux", "Haze", "Iris"]
            let name = tokens.first.map(String.init) ?? names.randomElement()!
            let task: String? = tokens.count > 1 ? String(tokens[1]) : nil
            try await summonAgent(name: name, task: task)
        } else if text.hasPrefix("@") {
            let parts = text.dropFirst().split(separator: " ", maxSplits: 1)
            let name = parts.first.map(String.init) ?? ""
            let message = parts.count > 1 ? String(parts[1]) : "hello"
            if let agent = agents.first(where: { $0.agentName.lowercased() == name.lowercased() }) {
                await chatWithAgent(agent, userText: text)
            } else {
                mainChatMessages.append(ChatMessage(role: .user, text: text))
                mainChatMessages.append(ChatMessage(role: .assistant, text: "No agent found with name \"\(name)\". Use /summon \(name) <task> to create one."))
            }
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

    /// Send a message to an agent via Claude and append to main chat
    private func chatWithAgent(_ agent: BrowserAgent, userText: String) async {
        mainChatMessages.append(ChatMessage(role: .user, text: userText))

        // Show a loading placeholder
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
            let response = try await ClaudeService.shared.send(
                system: agent.systemPrompt,
                messages: agent.claudeHistory
            )

            agent.claudeHistory.append(.init(role: "assistant", content: response))
            agent.cost += 0.02

            // Replace loading message with actual response
            if let idx = mainChatMessages.firstIndex(where: { $0.id == loadingMsg.id }) {
                mainChatMessages[idx].text = response
                mainChatMessages[idx].isLoading = false
            }
        } catch {
            // Replace loading message with error
            if let idx = mainChatMessages.firstIndex(where: { $0.id == loadingMsg.id }) {
                mainChatMessages[idx].text = "Error: \(error.localizedDescription)"
                mainChatMessages[idx].isLoading = false
            }
        }
    }

}
