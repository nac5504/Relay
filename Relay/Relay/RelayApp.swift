import SwiftUI

@main
struct RelayApp: App {
    @State private var backend = BackendProcess.shared
    @State private var isReady = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .overlay {
                    if !isReady {
                        Color(white: 0.06)
                            .overlay {
                                VStack(spacing: 20) {
                                    Image("logo")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 80, height: 80)

                                    Text("Relay")
                                        .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                                        .foregroundStyle(.white)

                                    ProgressView()
                                        .controlSize(.regular)
                                        .tint(.white.opacity(0.6))
                                        .padding(.top, 8)

                                    Text("Starting backend...")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.3))
                                }
                            }
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.6), value: isReady)
                .onAppear {
                    for window in NSApplication.shared.windows {
                        window.isOpaque = false
                        window.backgroundColor = .clear
                    }
                    backend.start()

                    Task {
                        await backend.ensureReady()
                        withAnimation {
                            isReady = true
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    backend.stop()
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}
