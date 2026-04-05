import SwiftUI

@main
struct RelayApp: App {
    init() {
        restartBackend()
        WebSocketManager.shared.connect()
        Task { await AgentStore.shared.load() }
    }

    private func restartBackend() {
        let scriptDir = findProjectRoot()
        guard let dir = scriptDir else {
            print("[RelayApp] Could not find project root — skipping backend restart")
            return
        }

        let kill = dir.appendingPathComponent("kill.sh")
        let startup = dir.appendingPathComponent("startup.sh")

        guard FileManager.default.fileExists(atPath: kill.path),
              FileManager.default.fileExists(atPath: startup.path) else {
            print("[RelayApp] kill.sh or startup.sh not found at \(dir.path)")
            return
        }

        // Run kill then startup synchronously so backend is ready before we connect
        runScript(kill)
        runScript(startup)
    }

    private func runScript(_ url: URL) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-l", url.path]  // login shell to load PATH from profile
        proc.currentDirectoryURL = url.deletingLastPathComponent()

        // Ensure node/npm/docker are in PATH
        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "\(NSHomeDirectory())/.nvm/versions/node/\(nodeVersion())/bin",
            "/Applications/Docker.app/Contents/Resources/bin",
        ]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if !output.isEmpty { print("[RelayApp] \(url.lastPathComponent):\n\(output)") }
            print("[RelayApp] \(url.lastPathComponent) exited with \(proc.terminationStatus)")
        } catch {
            print("[RelayApp] Failed to run \(url.lastPathComponent): \(error)")
        }
    }

    /// Find the active nvm node version, or fallback
    private func nodeVersion() -> String {
        let nvmDir = "\(NSHomeDirectory())/.nvm/versions/node"
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: nvmDir),
           let latest = contents.sorted().last {
            return latest
        }
        return "v22.0.0"  // fallback
    }

    private func findProjectRoot() -> URL? {
        // Walk up from the app bundle to find the project root containing startup.sh
        var dir = Bundle.main.bundleURL
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("startup.sh").path) {
                return dir
            }
        }
        // Fallback: check common dev path
        let fallback = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop/ramp-intern-hackathon")
        if FileManager.default.fileExists(atPath: fallback.appendingPathComponent("startup.sh").path) {
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
