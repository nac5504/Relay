import SwiftUI

struct BrowserTileView: View {
    @Bindable var agent: BrowserAgent
    var isMentioned: Bool = false
    var onClose: () -> Void

    @State private var showKillConfirmation = false
    @State private var idlePulse = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if agent.noVNCPort > 0, agent.noVNCURL != nil {
                BrowserStreamView(
                    agent: agent,
                    onFPSUpdate: { fps in
                        agent.fps = fps
                    }
                )
            } else if agent.relayStatus == .error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text(agent.errorMessage ?? "Unknown error")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.8))
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Starting \(agent.agentName)...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.8))
            }

            // Kill button (top-right)
            Button {
                showKillConfirmation = true
            } label: {
                Image(systemName: "trash.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .white.opacity(0.3))
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isMentioned ? Color.blue : borderColor, lineWidth: isMentioned ? 3 : 2)
                .opacity(isIdleStatus && !isMentioned ? (idlePulse ? 0.3 : 1.0) : 1.0)
        )
        .shadow(color: isMentioned ? Color.blue.opacity(0.6) : .clear, radius: 16, x: 0, y: 0)
        .animation(.easeInOut(duration: 0.25), value: isMentioned)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                idlePulse = true
            }
        }
        .alert("Kill Agent", isPresented: $showKillConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Kill", role: .destructive) { onClose() }
        } message: {
            Text("Are you sure you want to kill \(agent.agentName)? This cannot be undone.")
        }
    }

    private var isIdleStatus: Bool {
        agent.relayStatus == .waiting || agent.relayStatus == .notStarted
    }

    private var borderColor: Color {
        agent.relayStatus.dotColor
    }
}
