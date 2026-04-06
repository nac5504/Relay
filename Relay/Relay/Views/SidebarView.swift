import SwiftUI

struct SidebarView: View {
    let store: AgentStore
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Logo area
            HStack(spacing: 10) {
                Image("logo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)

                Text("Relay")
                    .font(.system(.title3, design: .monospaced).bold())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Thick separator — Conductor style
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    // Home button
                    SidebarRow(
                        icon: "house",
                        label: "Home",
                        isSelected: store.focusedAgentId == nil
                    ) {
                        store.unfocus()
                    }
                    .padding(.top, 8)

                    // Agent rows
                    ForEach(store.agents) { agent in
                        AgentSidebarRow(
                            agent: agent,
                            store: store
                        )
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer()

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            Button { showSettings = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 20)
                    Text("Settings")
                        .font(.system(.callout, design: .monospaced))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(
            ZStack {
                Color.black.opacity(0.4)
                Color.clear.background(.thinMaterial)
            }
        )
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 1),
            alignment: .trailing
        )
    }
}

// MARK: - Sidebar Row

private struct SidebarRow: View {
    let icon: String
    let label: String
    var isSelected: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 20)
                Text(label)
                    .font(.system(.callout, design: .monospaced))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .white : .white.opacity(0.6))
    }
}

// MARK: - Agent Row (expandable)

private struct AgentSidebarRow: View {
    let agent: BrowserAgent
    let store: AgentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Agent header
            Button {
                store.focusOnAgent(agent)
            } label: {
                HStack(spacing: 10) {
                    CachedAvatarView(url: agent.avatarURL, size: 22)

                    Text(agent.agentName)
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .lineLimit(1)

                    Spacer()

                    HStack(spacing: 5) {
                        Circle()
                            .fill(agent.relayStatus.dotColor)
                            .frame(width: 6, height: 6)
                        Text(agent.relayStatus.sidebarLabel)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(agent.relayStatus.dotColor.opacity(0.8))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(store.focusedAgentId == agent.id ? Color.white.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.7))

            // Plan steps checklist
            if !agent.planSteps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(agent.planSteps) { step in
                        HStack(spacing: 6) {
                            switch step.status {
                            case .active:
                                ProgressView()
                                    .controlSize(.mini)
                                    .scaleEffect(0.7)
                                    .frame(width: 12, height: 12)
                            case .completed:
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.green)
                                    .frame(width: 12, height: 12)
                            case .failed:
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.red)
                                    .frame(width: 12, height: 12)
                            case .pending:
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                                    .frame(width: 10, height: 10)
                                    .frame(width: 12, height: 12)
                            }

                            Text(step.shortDescription)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(
                                    step.status == .active ? .white.opacity(0.8) :
                                    step.status == .completed ? .white.opacity(0.4) :
                                    .white.opacity(0.3)
                                )
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.leading, 42)
                .padding(.trailing, 10)
                .padding(.top, 2)
            } else if !agent.task.isEmpty {
                // Fallback: show task description if no plan steps yet
                Text(agent.task)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                    .lineLimit(2)
                    .padding(.leading, 42)
                    .padding(.trailing, 10)
            }
        }
    }
}
