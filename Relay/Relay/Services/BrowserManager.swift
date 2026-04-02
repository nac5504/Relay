import Foundation

@Observable
class BrowserManager {
    var agents: [BrowserAgent] = []
    private let portAllocator = PortAllocator()
    private var agentCounter = 0

    private let dockerPath: String = {
        for path in ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"] {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return "/usr/local/bin/docker"
    }()

    var isDockerAvailable: Bool {
        FileManager.default.fileExists(atPath: dockerPath)
    }

    /// Remove any leftover relay-agent containers from previous runs
    func cleanupStaleContainers() async {
        if let output = try? await runDocker(arguments: [
            "ps", "-a", "--filter", "name=relay-agent", "-q"
        ]) {
            let ids = output.split(separator: "\n").map(String.init)
            for id in ids where !id.isEmpty {
                _ = try? await runDocker(arguments: ["rm", "-f", id])
            }
        }
    }

    func startAgent() async throws -> BrowserAgent {
        agentCounter += 1
        let ports = portAllocator.allocate()
        let agent = BrowserAgent(
            noVNCPort: ports.noVNC,
            vncPort: ports.vnc,
            seleniumPort: ports.selenium,
            displayName: "Agent \(agentCounter)"
        )
        agents.append(agent)

        let containerName = "relay-agent-\(agent.id.uuidString.prefix(8).lowercased())"

        do {
            let containerID = try await runDocker(arguments: [
                "run", "-d",
                "-p", "\(ports.noVNC):7900",
                "-p", "\(ports.vnc):5900",
                "-p", "\(ports.selenium):4444",
                "--shm-size=2g",
                "-e", "SE_SCREEN_WIDTH=1280",
                "-e", "SE_SCREEN_HEIGHT=720",
                "-e", "SE_VNC_PASSWORD=secret",
                "--name", containerName,
                "seleniarm/standalone-chromium:latest"
            ])

            agent.containerID = containerID.trimmingCharacters(in: .whitespacesAndNewlines)

            // Wait for noVNC + VNC to become available
            try await waitForReady(port: ports.noVNC, vncPort: ports.vnc, timeout: 30)

            // Launch Chromium inside the container
            _ = try? await runDocker(arguments: [
                "exec", "-d", containerName,
                "bash", "-c",
                "DISPLAY=:99.0 chromium --no-sandbox --disable-gpu --start-maximized --no-first-run --disable-session-crashed-bubble --disable-infobars 2>/dev/null &"
            ])

            agent.status = .running
        } catch {
            agent.status = .error
            agent.errorMessage = error.localizedDescription
            throw error
        }

        return agent
    }

    func stopAgent(_ agent: BrowserAgent) async {
        agent.status = .stopping
        if let containerID = agent.containerID {
            _ = try? await runDocker(arguments: ["rm", "-f", containerID])
        }
        portAllocator.release(noVNCPort: agent.noVNCPort)
        agent.status = .stopped
        agents.removeAll { $0.id == agent.id }
    }

    func stopAll() async {
        for agent in agents {
            agent.status = .stopping
            if let containerID = agent.containerID {
                _ = try? await runDocker(arguments: ["rm", "-f", containerID])
            }
            portAllocator.release(noVNCPort: agent.noVNCPort)
        }
        agents.removeAll()
    }

    // MARK: - Private

    nonisolated private func runDocker(arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [dockerPath] in
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()

                process.executableURL = URL(fileURLWithPath: dockerPath)
                process.arguments = arguments
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                    process.waitUntilExit()

                    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: outData, encoding: .utf8) ?? ""
                    let errOutput = String(data: errData, encoding: .utf8) ?? ""

                    if process.terminationStatus != 0 {
                        continuation.resume(throwing: BrowserError.dockerFailed(
                            status: process.terminationStatus,
                            stderr: errOutput
                        ))
                    } else {
                        continuation.resume(returning: output)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private func waitForReady(port: Int, vncPort: Int, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let url = URL(string: "http://localhost:\(port)/")!

        // Phase 1: Wait for HTTP (noVNC page)
        while Date() < deadline {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    break
                }
            } catch {
                // Container not ready yet
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        // Phase 2: Wait for VNC port to accept connections
        while Date() < deadline {
            if checkPort(vncPort) {
                // Give VNC and websockify proxy time to fully initialize
                try await Task.sleep(for: .seconds(2))
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        throw BrowserError.timeout(port: port)
    }

    /// Check if a TCP port is accepting connections
    nonisolated private func checkPort(_ port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

enum BrowserError: LocalizedError {
    case dockerFailed(status: Int32, stderr: String)
    case timeout(port: Int)

    var errorDescription: String? {
        switch self {
        case .dockerFailed(let status, let stderr):
            return "Docker failed (exit \(status)): \(stderr)"
        case .timeout(let port):
            return "Timed out waiting for container on port \(port)"
        }
    }
}
