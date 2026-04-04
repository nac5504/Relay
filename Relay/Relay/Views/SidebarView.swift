import SwiftUI

struct SidebarView: View {
    let store: AgentStore
    @State private var showSettings = false
    @State private var showNewAgentSheet = false
    @State private var newTaskText = ""
    @State private var isCreating = false

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

            // New Task button
            Button { showNewAgentSheet = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 20)
                    Text("New Task")
                        .font(.system(.callout, design: .monospaced))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

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
        .sheet(isPresented: $showNewAgentSheet) {
            VStack(spacing: 16) {
                Text("New Agent Task")
                    .font(.system(.headline, design: .monospaced))
                    .foregroundStyle(.white)

                TextEditor(text: $newTaskText)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(height: 120)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.04))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1)))
                    )

                HStack {
                    Button("Cancel") {
                        showNewAgentSheet = false
                        newTaskText = ""
                    }
                    Spacer()
                    Button(isCreating ? "Starting..." : "Create") {
                        isCreating = true
                        Task {
                            try? await store.createAgent(task: newTaskText)
                            isCreating = false
                            showNewAgentSheet = false
                            newTaskText = ""
                        }
                    }
                    .disabled(newTaskText.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 420)
            .background(Color(white: 0.08))
            .preferredColorScheme(.dark)
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

                    Circle()
                        .fill(agent.relayStatus.dotColor)
                        .frame(width: 8, height: 8)
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

            // Task description
            if !agent.task.isEmpty {
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
