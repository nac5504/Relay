import SwiftUI

struct MainChatView: View {
    let store: AgentStore
    @State private var inputText = ""

    private var hasWorkingAgent: Bool {
        store.agents.contains { $0.relayStatus == .working }
    }

    /// Find the agent that owns a .plan or .planRevised message by agentName
    private func agentForPlanMessage(_ msg: ChatMessage) -> BrowserAgent? {
        guard let name = msg.agentName else { return nil }
        return store.agents.first(where: { $0.agentName == name })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(store.filteredMainChatMessages.enumerated()), id: \.element.id) { i, msg in
                            // Skip output messages merged into preceding bash card
                            if msg.role == .output && i > 0 && store.filteredMainChatMessages[i - 1].role == .action && store.filteredMainChatMessages[i - 1].actionKind == .bash {
                                EmptyView()
                            } else if msg.role == .assistant && msg.text.contains("<plan/>") {
                                // Assistant message with embedded plan
                                let planAgent = agentForPlanMessage(msg)
                                let parts = msg.text.components(separatedBy: "<plan/>")
                                let snapshot = planAgent?.planSnapshots[msg.id]
                                let isCurrentPlan = msg.id == planAgent?.currentPlanMessageId
                                VStack(alignment: .leading, spacing: 8) {
                                    if let before = parts.first, !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        MarkdownTextView(text: before.trimmingCharacters(in: .whitespacesAndNewlines))
                                    }
                                    if isCurrentPlan {
                                        PlanChecklist(
                                            steps: snapshot?.steps ?? planAgent?.planSteps ?? [],
                                            version: snapshot?.version ?? planAgent?.planVersion ?? 1
                                        )
                                    } else {
                                        PlanRevisedIndicator()
                                    }
                                    if parts.count > 1 {
                                        let after = parts.dropFirst().joined(separator: "").trimmingCharacters(in: .whitespacesAndNewlines)
                                        if !after.isEmpty {
                                            MarkdownTextView(text: after)
                                        }
                                    }
                                }
                                .padding(.bottom, 14)
                                .id(msg.id)
                            } else {
                                let isLast = i == store.filteredMainChatMessages.count - 1 && !hasWorkingAgent
                                let status = actionStatus(at: i, in: store.filteredMainChatMessages)
                                let avatarURL = msg.agentName.flatMap { name in
                                    store.agents.first(where: { $0.agentName == name })?.avatarURL
                                }
                                let isLastForAgent: Bool = {
                                    guard let name = msg.agentName else { return false }
                                    if i == store.filteredMainChatMessages.count - 1 { return true }
                                    return !store.filteredMainChatMessages[(i + 1)...].contains { $0.agentName == name }
                                }()
                                let bashOutput: String? = (msg.role == .action && msg.actionKind == .bash && i + 1 < store.filteredMainChatMessages.count && store.filteredMainChatMessages[i + 1].role == .output) ? store.filteredMainChatMessages[i + 1].text : nil
                                MainTimelineRow(
                                    message: msg,
                                    isLastForAgent: isLastForAgent,
                                    showLine: !isLast,
                                    isFirstRow: i == 0,
                                    status: status,
                                    agentAvatarURL: avatarURL,
                                    agentColor: agentLineColor(for: msg.agentName),
                                    outputText: bashOutput
                                )
                                .id(msg.id)
                            }
                        }

                        if hasWorkingAgent && store.filteredMainChatMessages.last?.role != .user {
                            MainThinkingRow()
                                .id("main-thinking")
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                }
                .onChange(of: store.filteredMainChatMessages.count) { _, _ in
                    if hasWorkingAgent {
                        withAnimation { proxy.scrollTo("main-thinking", anchor: .bottom) }
                    } else if let last = store.filteredMainChatMessages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: store.filteredMainChatMessages.last?.text) { _, _ in
                    if let last = store.filteredMainChatMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Spacer(minLength: 0)

            CommandInputView(
                text: $inputText,
                placeholder: store.focusedAgent != nil
                    ? "Message \(store.focusedAgent!.agentName)..."
                    : "@agent task, /summon name task...",
                suggestionsProvider: provideSuggestions,
                onSend: { text in
                    store.mentionedAgentId = nil
                    Task { try? await store.processMainChatInput(text) }
                }
            )
        }
        .onChange(of: inputText) { _, newValue in
            store.updateMentionedAgent(from: newValue)
        }
        .onChange(of: store.focusedAgentId) { _, _ in
            inputText = ""
        }
        .background(
            ZStack {
                Color.black.opacity(0.4)
                Color.clear.background(.thinMaterial)
            }
        )
    }

    private func provideSuggestions(_ trigger: String) -> [AutocompleteSuggestion] {
        if trigger.hasPrefix("@") {
            let q = String(trigger.dropFirst()).lowercased()
            return store.agents
                .filter { q.isEmpty || $0.agentName.lowercased().hasPrefix(q) }
                .map {
                    AutocompleteSuggestion(
                        id: "agent-\($0.id)",
                        label: "@\($0.agentName)", hint: $0.relayStatus.displayName,
                        color: $0.relayStatus.dotColor, insertText: "@\($0.agentName)",
                        avatarURL: $0.avatarURL
                    )
                }
        } else if trigger.hasPrefix("/") {
            let q = String(trigger.dropFirst()).lowercased()
            let cmds: [(name: String, hint: String, insert: String?)] = [
                ("file", "Attach a file", nil),
                ("summon", "Spawn a new agent", nil),
                ("focus", "Zoom into an agent", "/focus @"),
                ("stop", "Stop an agent", nil),
                ("status", "Check agent status", nil),
            ]
            return cmds
                .filter { q.isEmpty || $0.name.lowercased().hasPrefix(q) }
                .map {
                    AutocompleteSuggestion(
                        id: "cmd-\($0.name)",
                        label: "/\($0.name)", hint: $0.hint,
                        color: .cyan, insertText: $0.insert ?? "/\($0.name)"
                    )
                }
        }
        return []
    }
}

// MARK: - Main Timeline Row

private struct MainTimelineRow: View {
    let message: ChatMessage
    let isLastForAgent: Bool
    let showLine: Bool
    let isFirstRow: Bool
    let status: ActionStatus
    var agentAvatarURL: URL? = nil
    var agentColor: Color = .white.opacity(0.15)
    var outputText: String? = nil

    private var dotColor: Color {
        if message.isError { return .white.opacity(0.4) }
        if message.role == .user { return .white.opacity(0.35) }
        return .white.opacity(0.2)
    }

    private var lineColor: Color {
        return .white.opacity(0.06)
    }

    private var dotSize: CGFloat {
        (message.role == .action || message.role == .output) ? 5 : 4
    }

    private var topLineHeight: CGFloat {
        (message.role == .action || message.role == .output) ? 7 : 8
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Timeline dot + connecting lines
            VStack(spacing: 0) {
                if isFirstRow {
                    Color.clear.frame(width: 0.5, height: topLineHeight)
                } else {
                    Rectangle()
                        .fill(lineColor)
                        .frame(width: 0.5, height: topLineHeight)
                }

                Circle()
                    .fill(dotColor)
                    .frame(width: dotSize, height: dotSize)

                if showLine {
                    Rectangle()
                        .fill(lineColor)
                        .frame(width: 0.5)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 8)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                // Agent name only on the most recent message from this agent
                if isLastForAgent && message.role != .user, let name = message.agentName {
                    HStack(spacing: 6) {
                        if let url = agentAvatarURL {
                            CachedAvatarView(url: url, size: 16)
                        }
                        Text(name)
                            .font(.system(.caption, design: .rounded, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .padding(.bottom, 4)
                }

                messageContent
            }
            .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(inlineAttributed(message.text))
                    .font(.system(.callout, design: .rounded, weight: .regular))
                    .foregroundStyle(.white.opacity(0.95))
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                            )
                    )
            }

        case .assistant where message.isLoading:
            PanelThinkingDots()

        case .assistant:
            MarkdownTextView(text: message.text)

        case .output:
            OutputBlock(text: message.text)

        case .action:
            if message.actionKind == .bash {
                BashCard(message: message, status: status, outputText: outputText)
            } else if message.actionKind == .screenshot {
                ScreenshotCard(status: status)
            } else {
                ActionCard(message: message, status: status)
            }

        case .thinking:
            ThinkingContent(message: message)

        case .system:
            ErrorOrSystemContent(message: message)

        case .plan, .planRevised:
            EmptyView() // Handled inline before reaching this view
        }
    }
}

// MARK: - Main Thinking Row

private struct MainThinkingRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 0.5, height: 8)
                PulsingDot()
            }
            .frame(width: 8)

            HStack(spacing: 8) {
                PanelThinkingDots()
                Text("Thinking")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
    }
}

// MARK: - Colored Text Helper

func agentLineColor(for name: String?) -> Color {
    let palette: [Color] = [.cyan, .pink, .orange, .mint, .purple, .yellow, .green, .indigo]
    guard let name = name, !name.isEmpty else { return .white.opacity(0.15) }
    let hash = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    return palette[hash % palette.count]
}

// Inline attributed string rendering moved to MarkdownTextView.swift
