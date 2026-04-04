import SwiftUI

struct HomeGridView: View {
    @Bindable var store: MockAgentStore

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack(spacing: 12) {
                if let agent = store.focusedAgent {
                    CachedAvatarView(url: agent.avatarURL, size: 36)
                        .transition(.scale.combined(with: .opacity))

                    Text(agent.agentName)
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .transition(.push(from: .bottom))
                } else {
                    Text("All Agents")
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .transition(.push(from: .top))
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .animation(.spring(response: 0.4, dampingFraction: 0.9), value: store.focusedAgentId)

            // Grid
            ZStack(alignment: .bottomLeading) {
                BrowserGridView(
                    agents: store.agents,
                    mentionedAgentId: store.mentionedAgentId,
                    onCloseAgent: { agent in
                        Task { try? await store.deleteAgent(agent) }
                    },
                    onSelectAgent: { agent in
                        store.focusOnAgent(agent)
                    },
                    selectedAgentId: $store.focusedAgentId
                )

                if store.focusedAgentId != nil {
                    Button {
                        store.unfocus()
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
                    .animation(.easeOut(duration: 0.25), value: store.focusedAgentId)
                }
            }
        }
    }
}
