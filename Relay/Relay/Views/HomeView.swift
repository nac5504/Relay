import SwiftUI

struct HomeGridView: View {
    let store: MockAgentStore
    @Binding var selectedAgentId: UUID?

    @State private var focusedAgentId: UUID?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            BrowserGridView(
                agents: store.agents,
                mentionedAgentId: store.mentionedAgentId,
                onCloseAgent: { agent in
                    Task { try? await store.deleteAgent(agent) }
                },
                selectedAgentId: $focusedAgentId
            )

            if focusedAgentId != nil {
                Button {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                        focusedAgentId = nil
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2")
                        Text("Return Home")
                    }
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}
