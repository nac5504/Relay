import SwiftUI

@main
struct RelayApp: App {
    init() {
        // Backend is started manually via `cd backend && pnpm dev`
        Task {
            await RelayApp.waitForBackend()
            WebSocketManager.shared.connect()
            await AgentStore.shared.load()
        }
    }

    private func startBackendProcess() {
        // Clean up stale relay-agent Docker containers
        let cleanupProc = Process()
        cleanupProc.executableURL = URL(fileURLWithPath: "/bin/bash")
        cleanupProc.arguments = ["-c", "docker ps -a --filter name=relay-agent -q | xargs -r docker rm -f 2>/dev/null || true"]
        cleanupProc.environment = shellEnv()
        try? cleanupProc.run()
        cleanupProc.waitUntilExit()
        print("[RelayApp] Cleaned up stale relay-agent containers")

        // Kill anything already on port 3001
        let killProc = Process()
        killProc.executableURL = URL(fileURLWithPath: "/bin/bash")
        killProc.arguments = ["-c", "lsof -ti :3001 | xargs kill 2>/dev/null || true"]
        killProc.environment = shellEnv()
        try? killProc.run()
        killProc.waitUntilExit()

        guard let backendDir = findBackendDir() else {
            print("[RelayApp] Could not find backend directory — skipping backend start")
            return
        }

        let pnpmPath = findPnpm()
        print("[RelayApp] Starting backend via \(pnpmPath) dev in \(backendDir.path)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpmPath)
        proc.arguments = ["dev"]
        proc.currentDirectoryURL = backendDir
        proc.environment = shellEnv()

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        // Log backend output asynchronously
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                print("[RelayApp backend] \(str)", terminator: "")
            }
        }

        do {
            try proc.run()
            print("[RelayApp] Backend started (PID \(proc.processIdentifier))")
        } catch {
            print("[RelayApp] Failed to start backend: \(error)")
        }
    }

    private static func waitForBackend() async {
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            do {
                var request = URLRequest(url: URL(string: "http://localhost:3001/health")!)
                request.timeoutInterval = 2
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    print("[RelayApp] Backend is ready on http://localhost:3001")
                    return
                }
            } catch {
                continue
            }
        }
        print("[RelayApp] Backend did not become ready within 30s")
    }

    private func shellEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "\(NSHomeDirectory())/.nvm/versions/node/\(nodeVersion())/bin",
            "\(NSHomeDirectory())/Library/pnpm",
            "/Applications/Docker.app/Contents/Resources/bin",
        ]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        return env
    }

    private func findPnpm() -> String {
        for dir in ["\(NSHomeDirectory())/Library/pnpm", "/opt/homebrew/bin", "/usr/local/bin"] {
            let path = "\(dir)/pnpm"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "/opt/homebrew/bin/pnpm"
    }

    /// Find the active nvm node version, or fallback
    private func nodeVersion() -> String {
        let nvmDir = "\(NSHomeDirectory())/.nvm/versions/node"
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: nvmDir),
           let latest = contents.sorted().last {
            return latest
        }
        return "v22.0.0"
    }

    private func findBackendDir() -> URL? {
        // Walk up from the app bundle to find the project root containing backend/
        var dir = Bundle.main.bundleURL
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent("backend/package.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return dir.appendingPathComponent("backend")
            }
        }
        let fallback = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop/ramp-intern-hackathon/backend")
        if FileManager.default.fileExists(atPath: fallback.appendingPathComponent("package.json").path) {
            return fallback
        }
        return nil
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    for window in NSApplication.shared.windows {
                        window.isOpaque = false
                        window.backgroundColor = .clear
                    }
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}
