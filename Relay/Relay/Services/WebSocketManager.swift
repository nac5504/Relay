import Foundation

@Observable
final class WebSocketManager: @unchecked Sendable {
    static let shared = WebSocketManager()
    private init() {}

    private var task: URLSessionWebSocketTask?
    private var reconnectDelay: TimeInterval = 1
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        return URLSession(configuration: config)
    }()
    var isConnected = false

    func connect() {
        // Cancel existing task
        task?.cancel(with: .normalClosure, reason: nil)

        let url = URL(string: "ws://localhost:3001")!
        let wsTask = session.webSocketTask(with: url)
        self.task = wsTask
        wsTask.resume()
        reconnectDelay = 1
        print("[WS] Connecting to \(url)")
        receive(wsTask)
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        DispatchQueue.main.async { self.isConnected = false }
    }

    private func receive(_ wsTask: URLSessionWebSocketTask) {
        wsTask.receive { [weak self] result in
            guard let self, self.task === wsTask else { return }

            switch result {
            case .failure(let error):
                print("[WS] Receive error: \(error.localizedDescription)")
                DispatchQueue.main.async { self.isConnected = false }
                self.scheduleReconnect()

            case .success(let message):
                DispatchQueue.main.async { self.isConnected = true }
                if case .string(let text) = message {
                    self.handle(text)
                }
                self.receive(wsTask)
            }
        }
    }

    private func scheduleReconnect() {
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        print("[WS] Reconnecting in \(delay)s...")
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        DispatchQueue.main.async {
            let store = AgentStore.shared

            switch type {
            case "connected":
                print("[WS] Connected to backend")
                self.isConnected = true

            case "agent_update":
                guard let agentId = json["agentId"] as? String else { return }
                store.updateAgent(id: agentId) { agent in
                    if let status = json["status"] as? String {
                        agent.relayStatus = RelayAgentStatus(rawValue: status) ?? agent.relayStatus
                        agent.waitingForInput = (status == "waiting")
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
