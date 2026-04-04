import SwiftUI

struct SidebarView: View {
    let store: MockAgentStore
    @Binding var selectedAgentId: UUID?
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
                        isSelected: selectedAgentId == nil
                    ) {
                        selectedAgentId = nil
                    }
                    .padding(.top, 8)

                    // Agent rows
                    ForEach(store.agents) { agent in
                        AgentSidebarRow(
                            agent: agent,
                            selectedAgentId: $selectedAgentId
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
            .padding(.vertical, 8)
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

// MARK: - Agent Row (expandable with tasks)

private struct AgentSidebarRow: View {
    let agent: BrowserAgent
    @Binding var selectedAgentId: UUID?
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Agent header
            Button {
                selectedAgentId = agent.id
            } label: {
                HStack(spacing: 10) {
                    CachedAvatarView(url: agent.avatarURL, size: 22)

                    Text(agent.agentName)
                        .font(.system(.callout, design: .monospaced).weight(.medium))

                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.3))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selectedAgentId == agent.id ? Color.white.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.7))

            // Task sub-items
            if isExpanded {
                ForEach(agent.tasks) { task in
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.pencil")
                            .font(.caption)
                            .frame(width: 16)
                            .foregroundStyle(.white.opacity(0.3))

                        Text(task.name)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)

                        Spacer()

                        Circle()
                            .fill(dotColor(for: task.status))
                            .frame(width: 8, height: 8)
                    }
                    .padding(.leading, 32)
                    .padding(.trailing, 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
    }

    private func dotColor(for status: AgentTask.TaskStatus) -> Color {
        switch status {
        case .active: return .green
        case .pending: return .gray
        case .completed: return .blue
        case .failed: return .red
        }
    }
}
