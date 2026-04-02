import SwiftUI

struct ContentView: View {
    @State private var browserManager = BrowserManager()
    @State private var isStarting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Relay")
                    .font(.title2.bold())

                Spacer()

                Text("\(browserManager.agents.count) agent(s)")
                    .foregroundStyle(.secondary)

                if !browserManager.agents.isEmpty {
                    let avgFPS = browserManager.agents.map(\.fps).reduce(0, +) / Double(max(browserManager.agents.count, 1))
                    Text("Avg: \(avgFPS, specifier: "%.1f") FPS")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(avgFPS >= 24 ? .green : (avgFPS >= 15 ? .yellow : .red))
                }

                Button("Add Agent") {
                    Task { await addAgent() }
                }
                .disabled(isStarting || browserManager.agents.count >= 6)

                Button("Stop All") {
                    Task { await browserManager.stopAll() }
                }
                .disabled(browserManager.agents.isEmpty)
            }
            .padding()

            Divider()

            // Grid
            if browserManager.agents.isEmpty {
                if !browserManager.isDockerAvailable {
                    ContentUnavailableView(
                        "Docker Not Found",
                        systemImage: "globe.badge.chevron.backward",
                        description: Text("Install Docker Desktop to use Relay")
                    )
                } else {
                    ContentUnavailableView(
                        "No Agents Running",
                        systemImage: "globe",
                        description: Text("Click \"Add Agent\" to start a browser container")
                    )
                }
            } else {
                ScrollView {
                    BrowserGridView(
                        agents: browserManager.agents,
                        onCloseAgent: { agent in
                            Task { await browserManager.stopAgent(agent) }
                        }
                    )
                }
            }

            // Error bar
            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss") { errorMessage = nil }
                        .buttonStyle(.plain)
                }
                .padding()
                .background(.red.opacity(0.1))
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .task {
            await browserManager.cleanupStaleContainers()
        }
        .onDisappear {
            Task { await browserManager.stopAll() }
        }
    }

    private func addAgent() async {
        isStarting = true
        defer { isStarting = false }
        do {
            _ = try await browserManager.startAgent()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
