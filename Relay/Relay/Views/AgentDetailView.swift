import SwiftUI

struct AgentDetailView: View {
    @Bindable var agent: BrowserAgent
    let store: AgentStore
    @State private var showChat = false

    var body: some View {
        ZStack(alignment: .trailing) {
            // Main content — full width stream
            VStack(spacing: 0) {
                // Top info bar
                HStack(spacing: 12) {
                    CachedAvatarView(url: agent.avatarURL, size: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.agentName)
                            .font(.system(.headline, design: .monospaced))
                            .foregroundStyle(.white)
                        Text(agent.currentTaskName)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                    }

                    Spacer()

                    // Status badge
                    HStack(spacing: 6) {
                        Circle()
                            .fill(agent.relayStatus.dotColor)
                            .frame(width: 8, height: 8)
                        Text(agent.relayStatus.displayName)
                            .font(.system(.caption, design: .monospaced).weight(.medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.06))
                            .overlay(Capsule().stroke(Color.white.opacity(0.06), lineWidth: 1))
                    )

                    // Cost
                    Text(agent.formattedCost)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))

                    // Chat toggle
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showChat.toggle()
                        }
                    } label: {
                        Image(systemName: showChat ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                            .font(.title3)
                            .foregroundStyle(showChat ? Color.accentColor : .white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Toggle chat panel")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(white: 0.05))

                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)

                // Stream area — show recording playback for completed agents, live stream for active
                if agent.relayStatus == .completed || agent.relayStatus == .stopped {
                    RecordingPlaybackView(agent: agent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if agent.noVNCPort > 0, let _ = agent.noVNCURL {
                    BrowserStreamView(agent: agent, onFPSUpdate: { agent.fps = $0 })
                } else {
                    // Loading placeholder
                    ZStack {
                        Color(white: 0.04)

                        VStack(spacing: 16) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(white: 0.08))
                                .frame(maxWidth: 600, maxHeight: 400)
                                .overlay(
                                    VStack(spacing: 8) {
                                        // Fake title bar
                                        HStack {
                                            HStack(spacing: 6) {
                                                Circle().fill(.red.opacity(0.6)).frame(width: 10, height: 10)
                                                Circle().fill(.yellow.opacity(0.6)).frame(width: 10, height: 10)
                                                Circle().fill(.green.opacity(0.6)).frame(width: 10, height: 10)
                                            }
                                            Spacer()
                                            Text("agent-desktop")
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(.white.opacity(0.2))
                                            Spacer()
                                            Color.clear.frame(width: 50)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color(white: 0.1))

                                        VStack(spacing: 4) {
                                            ForEach(0..<6, id: \.self) { i in
                                                RoundedRectangle(cornerRadius: 2)
                                                    .fill(Color.white.opacity(0.02))
                                                    .frame(height: 12)
                                                    .frame(maxWidth: CGFloat(150 + i * 40))
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        }
                                        .padding(12)

                                        Spacer()
                                    }
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                            ProgressView()
                                .scaleEffect(1.5)
                            Text("Starting container...")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            // Slide-in chat panel
            if showChat {
                ChatPanelView(agent: agent, store: store, onClose: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showChat = false
                    }
                })
                .frame(width: 340)
                .transition(.move(edge: .trailing))
            }
        }
        .background(.clear)
    }
}
