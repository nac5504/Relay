import Foundation

/// Manages the Node.js backend process lifecycle.
/// Starts automatically on app launch, stops on app quit.
@MainActor @Observable
class BackendProcess {
    static let shared = BackendProcess()

    var isRunning = false
    var isReady = false  // true once /health returns 200
    var error: String?

    private var process: Process?
    private var outputPipe: Pipe?

    /// Path to the backend directory (relative to the app's repo root)
    private var backendDir: String {
        // Walk up from the app bundle to find the repo root
        let bundle = Bundle.main.bundlePath
        // In dev: DerivedData/.../Relay.app → need to find the repo
        // Use a known marker: look for backend/server.js relative to common locations
        let candidates = [
            // Hardcoded repo path (works reliably during development)
            NSString("~/Desktop/ramp-intern-hackathon/backend").expandingTildeInPath,
            // Relative to bundle (production)
            (bundle as NSString).deletingLastPathComponent + "/backend",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0 + "/server.js") }
            ?? candidates[0]
    }

    private var nodePath: String {
        // Common Node.js locations on macOS
        let paths = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) } ?? "node"
    }

    func start() {
        guard !isRunning else { return }
        guard FileManager.default.fileExists(atPath: backendDir + "/server.js") else {
            error = "backend/server.js not found"
            return
        }

        // Kill any stale backend from a previous run
        killStaleBackend()

        // Check if node_modules exists, run npm install if not
        if !FileManager.default.fileExists(atPath: backendDir + "/node_modules") {
            installDependencies()
        }

        let proc = Process()
        let pipe = Pipe()

        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = ["server.js"]
        proc.currentDirectoryURL = URL(fileURLWithPath: backendDir)
        proc.standardOutput = pipe
        proc.standardError = pipe

        // GUI apps get a minimal PATH — inject the full set of paths
        // so Docker, docker-credential-desktop, node, etc. are all findable
        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "/Applications/Docker.app/Contents/Resources/bin",
        ]
        let currentPath = env["PATH"] ?? ""
        let merged = (extraPaths + currentPath.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        env["PATH"] = merged.joined(separator: ":")
        proc.environment = env

        proc.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.isRunning = false
                if process.terminationStatus != 0 && process.terminationStatus != 15 {
                    self?.error = "Backend exited with code \(process.terminationStatus)"
                }
            }
        }

        do {
            try proc.run()
            process = proc
            outputPipe = pipe
            isRunning = true
            isReady = false
            error = nil

            // Read output in background for debugging
            readOutput(pipe)

            // Poll /health until backend is accepting requests
            Task {
                await waitUntilReady()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Wait for the backend to respond to /health
    private func waitUntilReady() async {
        let url = URL(string: "http://localhost:3001/health")!
        for _ in 0..<60 { // 30 seconds max
            try? await Task.sleep(for: .milliseconds(500))
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    await MainActor.run { isReady = true }
                    return
                }
            } catch {
                continue
            }
        }
    }

    /// Wait until the backend is ready (for use by other services)
    func ensureReady() async {
        while !isReady {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    func stop() {
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        process = nil
        isRunning = false
    }

    private func killStaleBackend() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-ti:3001"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else { return }

        for pidStr in output.split(separator: "\n") {
            if let pid = Int32(pidStr) {
                kill(pid, SIGTERM)
            }
        }
        // Brief wait for port to free
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func installDependencies() {
        let npmPath = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]
            .first { FileManager.default.fileExists(atPath: $0) } ?? "npm"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: npmPath)
        proc.arguments = ["install"]
        proc.currentDirectoryURL = URL(fileURLWithPath: backendDir)
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        try? proc.run()
        proc.waitUntilExit()
    }

    private func readOutput(_ pipe: Pipe) {
        DispatchQueue.global(qos: .background).async {
            let handle = pipe.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                if let str = String(data: data, encoding: .utf8) {
                    // Log to console for debugging
                    print("[backend] \(str)", terminator: "")
                }
            }
        }
    }
}
