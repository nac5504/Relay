import Foundation

@Observable
final class WebSocketManager {
    static let shared = WebSocketManager()
    private init() {}

    private var task: URLSessionWebSocketTask?
    private var reconnectDelay: TimeInterval = 1
    var isConnected = false

    func connect() {
        let url = URL(string: "ws://localhost:3001")!
        task = URLSession.shared.webSocketTask(with: url)
        task?.resume()
        isConnected = true
        reconnectDelay = 1
        receive()
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        isConnected = false
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.isConnected = false
                let delay = self.reconnectDelay
                self.reconnectDelay = min(self.reconnectDelay * 2, 30)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.connect()
                }
            case .success(let message):
                if case .string(let text) = message {
                    self.handle(text)
                }
                self.receive()
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        DispatchQueue.main.async {
            let store = AgentStore.shared

            switch type {
            case "agent_update":
                guard let agentId = json["agentId"] as? String else { return }
                store.updateAgent(id: agentId) { agent in
                    if let status = json["status"] as? String {
                        agent.relayStatus = RelayAgentStatus(rawValue: status) ?? agent.relayStatus
                        agent.waitingForInput = (status == "waiting")
                        // Sync legacy status
                        if status == "completed" || status == "stopped" || status == "error" {
                            agent.status = .stopped
                        } else if status == "working" {
                            agent.status = .running
                        }
                    }
                    if let cost = json["cost"] as? Double { agent.cost = cost }
                    if let port = json["noVNCPort"] as? Int, port > 0 { agent.noVNCPort = port }
                    if let port = json["vncPort"] as? Int, port > 0 { agent.vncPort = port }
                }

            case "plan_message":
                guard let agentId = json["agentId"] as? String,
                      let role = json["role"] as? String,
                      let msgText = json["text"] as? String else { return }
                let streaming = json["streaming"] as? Bool ?? false
                store.appendPlanMessage(agentId: agentId, role: role, text: msgText, streaming: streaming)

            case "plan_complete":
                guard let agentId = json["agentId"] as? String else { return }
                store.updateAgent(id: agentId) { $0.planComplete = true }

            case "chat_message":
                guard let agentId = json["agentId"] as? String,
                      let role = json["role"] as? String,
                      let msgText = json["text"] as? String else { return }
                store.appendChatMessage(agentId: agentId, role: role, text: msgText)

            case "action":
                guard let agentId = json["agentId"] as? String,
                      let event = json["event"] as? [String: Any],
                      let desc = event["description"] as? String else { return }
                store.appendChatMessage(agentId: agentId, role: "action", text: desc)

            case "agent_added":
                if let agentData = json["agent"] as? [String: Any] {
                    store.upsertAgentFromJSON(agentData)
                }

            case "agent_removed":
                if let agentId = json["agentId"] as? String {
                    store.removeAgent(id: agentId)
                }

            case "files_ready":
                guard let agentId = json["agentId"] as? String,
                      let files = json["files"] as? [String] else { return }
                store.updateAgent(id: agentId) { $0.outputFiles = files }

            default:
                break
            }
        }
    }
}
