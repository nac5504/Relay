import Foundation

// MARK: - Response types matching backend JSON

struct AgentResponse: Codable, Identifiable {
    let id: String
    let agentName: String
    let task: String
    let status: String
    let noVNCPort: Int?
    let vncPort: Int?
    let sessionId: String
    let cost: Double
    let waitingForInput: Bool
    let containerReady: Bool?
    let error: String?
}

// MARK: - APIService

actor APIService {
    static let shared = APIService()
    private init() {}

    private let base = URL(string: "http://localhost:3001")!
    private let session = URLSession.shared

    private func request(_ path: String, method: String = "GET", body: (any Encodable)? = nil) async throws -> Data {
        var url = base
        for component in path.split(separator: "/").filter({ !$0.isEmpty }) {
            url.appendPathComponent(String(component))
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let (data, _) = try await session.data(for: req)
        return data
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await request(path)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        let data = try await request(path, method: "POST", body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Config

    func setApiKey(_ key: String) async throws {
        struct Body: Encodable { let apiKey: String }
        struct Resp: Decodable { let ok: Bool }
        let _: Resp = try await post("/config", body: Body(apiKey: key))
    }

    // MARK: - Agents

    func fetchAgents() async throws -> [AgentResponse] {
        try await get("/agents")
    }

    func createAgent(task: String, agentName: String? = nil) async throws -> AgentResponse {
        struct Body: Encodable { let task: String; let agentName: String? }
        return try await post("/agents", body: Body(task: task, agentName: agentName))
    }

    func deleteAgent(id: String) async throws {
        _ = try await request("/agents/\(id)", method: "DELETE")
    }

    func sendMessage(agentId: String, text: String) async throws {
        struct Body: Encodable { let text: String }
        _ = try await request("/agents/\(agentId)/message", method: "POST", body: Body(text: text))
    }

    // MARK: - Recordings & Outputs

    func fetchOutputFiles(agentId: String) async throws -> [String] {
        struct Resp: Decodable { let files: [String] }
        let resp: Resp = try await get("/recordings/\(agentId)/outputs")
        return resp.files
    }

    func recordingURL(sessionId: String) -> URL {
        var url = base
        url.appendPathComponent("recordings")
        url.appendPathComponent(sessionId)
        url.appendPathComponent("video")
        return url
    }

    func outputFileURL(agentId: String, filename: String) -> URL {
        var url = base
        url.appendPathComponent("recordings")
        url.appendPathComponent(agentId)
        url.appendPathComponent("outputs")
        url.appendPathComponent(filename)
        return url
    }
}
