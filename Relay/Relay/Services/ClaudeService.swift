import Foundation

actor ClaudeService {
    static let shared = ClaudeService()

    private let baseURL = "https://api.anthropic.com/v1/messages"

    private var apiKey: String {
        ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
            ?? UserDefaults.standard.string(forKey: "anthropic_api_key")
            ?? ""
    }

    private(set) var model = "claude-sonnet-4-6"
    private(set) var maxTokens = 512

    func setModel(_ newModel: String) {
        model = newModel
    }

    func setMaxTokens(_ newMax: Int) {
        maxTokens = newMax
    }

    struct Message: Codable {
        let role: String
        let content: String
    }

    func send(system: String, messages: [Message], maxTokensOverride: Int? = nil) async throws -> String {
        guard !apiKey.isEmpty else {
            return "No API key. Open Settings to add your Anthropic key."
        }

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("prompt-caching-2024-07-31", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokensOverride ?? maxTokens,
            "system": system,
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let err = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ClaudeService", code: 1, userInfo: [NSLocalizedDescriptionKey: err])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = json?["content"] as? [[String: Any]]
        return content?.first?["text"] as? String ?? "No response"
    }

    /// Stream response token-by-token via SSE. Each element yielded is a text delta.
    func stream(system: String, messages: [Message], maxTokensOverride: Int? = nil) async throws -> AsyncThrowingStream<String, Error> {
        guard !apiKey.isEmpty else {
            return AsyncThrowingStream { continuation in
                continuation.yield("No API key. Open Settings to add your Anthropic key.")
                continuation.finish()
            }
        }

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("prompt-caching-2024-07-31", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokensOverride ?? maxTokens,
            "system": system,
            "stream": true,
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let preparedRequest = request

        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: preparedRequest)

                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                        }
                        continuation.finish(throwing: NSError(
                            domain: "ClaudeService", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: errorBody.isEmpty ? "HTTP error" : errorBody]
                        ))
                        return
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard jsonStr != "[DONE]",
                              let data = jsonStr.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = event["type"] as? String,
                              type == "content_block_delta",
                              let delta = event["delta"] as? [String: Any],
                              let text = delta["text"] as? String else { continue }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
