import Foundation

extension Notification.Name {
    static let dockerBuildProgress = Notification.Name("dockerBuildProgress")
    static let dockerBuildComplete = Notification.Name("dockerBuildComplete")
}

@Observable
final class WebSocketManager: @unchecked Sendable {
    static let shared = WebSocketManager()
    private init() {}

    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectDelay: TimeInterval = 1
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        return URLSession(configuration: config)
    }()
    var isConnected = false

    func connect() {
        // Cancel existing
        receiveTask?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)

        let url = URL(string: "ws://localhost:3001")!
        let wsTask = session.webSocketTask(with: url)
        self.task = wsTask
        wsTask.resume()
        print("[WS] Connecting to \(url)")

        // Start receive loop in a Task
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(wsTask)
        }
    }

    private func receiveLoop(_ wsTask: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await wsTask.receive()
                if case .string(let text) = message {
                    handleOnMain(text)
                }
            } catch {
                print("[WS] Receive error: \(error.localizedDescription)")
                await MainActor.run { self.isConnected = false }
                scheduleReconnect()
                return
            }
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        isConnected = false
    }

    private func scheduleReconnect() {
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        print("[WS] Reconnecting in \(delay)s...")
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    private func handleOnMain(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        DispatchQueue.main.async {
            let store = AgentStore.shared

            switch type {
            case "connected":
                print("[WS] Connected to backend")
                self.isConnected = true
                self.reconnectDelay = 1

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
                // Surface errors as chat messages
                if let status = json["status"] as? String, status == "error" {
                    let errorText = json["error"] as? String ?? "Unknown error"
                    store.appendErrorMessage(agentId: agentId, text: errorText)
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
                      let msgText = json["text"] as? String else {
                    print("[WS] chat_message: missing fields in \(json)")
                    return
                }
                print("[WS] chat_message: agent=\(agentId.prefix(8)) role=\(role) text=\(msgText.prefix(60))")
                store.appendChatMessage(agentId: agentId, role: role, text: msgText)

            case "action":
                // Extract coordinates for cursor overlay
                if let agentId = json["agentId"] as? String,
                   let event = json["event"] as? [String: Any] {
                    let actionType = event["actionType"] as? String ?? "unknown"
                    if let coords = event["coordinates"] as? [String: Any],
                       let x = coords["x"] as? Double,
                       let y = coords["y"] as? Double {
                        store.updateAgentCursor(agentId: agentId, x: x, y: y, screenWidth: 2560, screenHeight: 1440, actionType: actionType)
                    }
                }
                // Chat text is handled via "chat_message" with role:"action"

            case "agent_added":
                if let agentData = json["agent"] as? [String: Any] {
                    store.upsertAgentFromJSON(agentData)
                }

            case "agent_removed":
                if let agentId = json["agentId"] as? String {
                    store.removeAgent(id: agentId)
                }

            case "task_list":
                guard let agentId = json["agentId"] as? String,
                      let steps = json["steps"] as? [String] else { return }
                store.updateAgent(id: agentId) { agent in
                    agent.planSteps = steps.enumerated().map { PlanStep(id: $0.offset, title: $0.element) }
                }

            case "task_update":
                guard let agentId = json["agentId"] as? String,
                      let stepIndex = json["stepIndex"] as? Int,
                      let completed = json["completed"] as? Bool else { return }
                store.updateAgent(id: agentId) { agent in
                    if stepIndex < agent.planSteps.count {
                        agent.planSteps[stepIndex].isCompleted = completed
                    }
                }

            case "files_ready":
                guard let agentId = json["agentId"] as? String,
                      let files = json["files"] as? [String] else { return }
                store.updateAgent(id: agentId) { $0.outputFiles = files }

            case "docker_build_progress":
                if let line = json["line"] as? String {
                    NotificationCenter.default.post(
                        name: .dockerBuildProgress,
                        object: nil,
                        userInfo: ["line": line]
                    )
                }

            case "docker_build_complete":
                let success = json["success"] as? Bool ?? false
                let error = json["error"] as? String
                NotificationCenter.default.post(
                    name: .dockerBuildComplete,
                    object: nil,
                    userInfo: ["success": success, "error": error as Any]
                )

            default:
                break
            }
        }
    }
}
