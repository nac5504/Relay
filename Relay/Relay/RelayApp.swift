import SwiftUI

@main
struct RelayApp: App {
    init() {
        WebSocketManager.shared.connect()
        Task { await AgentStore.shared.load() }
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
