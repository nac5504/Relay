import SwiftUI

struct MainChatView: View {
    let store: AgentStore
    @State private var inputText = ""

    private var hasWorkingAgent: Bool {
        store.agents.contains { $0.relayStatus == .working }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Show plan checklist for working agents
                        ForEach(store.agents.filter { !$0.planSteps.isEmpty }) { agent in
                            PlanChecklist(steps: agent.planSteps)
                                .padding(.horizontal, 0)
                                .padding(.bottom, 8)
                        }

                        ForEach(Array(store.mainChatMessages.enumerated()), id: \.element.id) { i, msg in
                            let isLast = i == store.mainChatMessages.count - 1 && !hasWorkingAgent
                            let status = actionStatus(at: i, in: store.mainChatMessages)
                            let avatarURL = msg.agentName.flatMap { name in
                                store.agents.first(where: { $0.agentName == name })?.avatarURL
                            }
                            let isLastForAgent: Bool = {
                                guard let name = msg.agentName else { return false }
                                if i == store.mainChatMessages.count - 1 { return true }
                                return !store.mainChatMessages[(i + 1)...].contains { $0.agentName == name }
                            }()
                            MainTimelineRow(
                                message: msg,
                                isLastForAgent: isLastForAgent,
                                showLine: !isLast,
                                isFirstRow: i == 0,
                                status: status,
                                agentAvatarURL: avatarURL,
                                agentColor: agentLineColor(for: msg.agentName)
                            )
                            .id(msg.id)
                        }

                        if hasWorkingAgent && store.mainChatMessages.last?.role != .user {
                            MainThinkingRow()
                                .id("main-thinking")
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                }
                .onChange(of: store.mainChatMessages.count) { _, _ in
                    if hasWorkingAgent {
                        withAnimation { proxy.scrollTo("main-thinking", anchor: .bottom) }
                    } else if let last = store.mainChatMessages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: store.mainChatMessages.last?.text) { _, _ in
                    if let last = store.mainChatMessages.last {
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

    private var dotColor: Color {
        if message.isError { return .red }
        if message.role == .user { return .accentColor.opacity(0.6) }
        return agentColor
    }

    private var lineColor: Color {
        if message.role == .user { return .white.opacity(0.08) }
        return agentColor.opacity(0.25)
    }

    private var dotSize: CGFloat {
        (message.role == .action || message.role == .output) ? 8 : 6
    }

    private var topLineHeight: CGFloat {
        (message.role == .action || message.role == .output) ? 5 : 6
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Timeline dot + connecting lines
            VStack(spacing: 0) {
                if isFirstRow {
                    Color.clear.frame(width: 1, height: topLineHeight)
                } else {
                    Rectangle()
                        .fill(lineColor)
                        .frame(width: 1, height: topLineHeight)
                }

                Circle()
                    .fill(dotColor)
                    .frame(width: dotSize, height: dotSize)

                if showLine {
                    Rectangle()
                        .fill(lineColor)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 10)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                // Agent name only on the most recent message from this agent
                if isLastForAgent && message.role != .user, let name = message.agentName {
                    HStack(spacing: 6) {
                        if let url = agentAvatarURL {
                            CachedAvatarView(url: url, size: 16)
                        }
                        Text(name)
                            .font(.system(.caption, design: .monospaced, weight: .semibold))
                            .foregroundStyle(agentColor.opacity(0.7))
                    }
                    .padding(.bottom, 2)
                }

                messageContent
            }
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(coloredText(message.text))
                    .font(.system(.callout, design: .default))
                    .foregroundStyle(.white.opacity(0.9))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.08))
                    )
            }

        case .assistant where message.isLoading:
            ThinkingDotsView()

        case .assistant:
            Text(coloredText(message.text))
                .font(.system(.callout, design: .default))
                .foregroundStyle(.white.opacity(0.85))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .output:
            MainOutputBlock(text: message.text)

        case .action:
            MainActionCard(message: message, status: status)

        case .thinking:
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                Text("Thinking...")
                    .font(.system(.caption2, design: .monospaced))
            }
            .foregroundStyle(.white.opacity(0.25))

        case .system:
            MainErrorOrSystem(message: message)
        }
    }
}

// MARK: - Main Action Card

private struct MainActionCard: View {
    let message: ChatMessage
    let status: ActionStatus

    private var borderColor: Color {
        switch status {
        case .success: return .green.opacity(0.3)
        case .failure: return .red.opacity(0.3)
        case .pending: return .white.opacity(0.08)
        case .neutral: return .white.opacity(0.08)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: message.actionKind.iconName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(message.actionKind.tintColor.opacity(0.7))
                .frame(width: 16, height: 16)

            Text(message.actionDisplayText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: 1)
        )
    }
}

// MARK: - Main Output Block

private struct MainOutputBlock: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text("Output")
                        .font(.system(.caption2, design: .monospaced))
                    Text("(\(text.components(separatedBy: "\n").count) lines)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.2))
                }
                .foregroundStyle(.white.opacity(0.35))
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .textSelection(.enabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.black.opacity(0.3))
                )
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Main Error / System

private struct MainErrorOrSystem: View {
    let message: ChatMessage

    var body: some View {
        if message.isError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                Text(message.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red.opacity(0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.red.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.red.opacity(0.2), lineWidth: 1)
            )
        } else {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.cyan.opacity(0.5))
                Text(message.text)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Main Thinking Row

private struct MainThinkingRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1, height: 6)
                MainPulsingDot()
            }
            .frame(width: 10)

            HStack(spacing: 6) {
                ThinkingDotsView()
                Text("Thinking...")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
    }
}

// MARK: - Pulsing Dot

private struct MainPulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(Color.cyan.opacity(isPulsing ? 0.6 : 0.2))
            .frame(width: 6, height: 6)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

// MARK: - Thinking Dots

private struct ThinkingDotsView: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.white.opacity(phase == i ? 0.8 : 0.25))
                    .frame(width: 6, height: 6)
                    .animation(.easeInOut(duration: 0.4), value: phase)
            }
        }
        .padding(.vertical, 6)
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                phase = (phase + 1) % 3
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

func coloredText(_ text: String) -> AttributedString {
    let patterns: [(regex: String, style: (inout AttributedString) -> Void)] = [
        (#"\*\*(.+?)\*\*"#, { $0.font = .system(.callout, design: .default, weight: .semibold) }),
        (#"\*(.+?)\*"#,     { $0.font = .system(.callout, design: .default).italic() }),
        (#"`([^`]+)`"#,     { attr in
            attr.font = .system(.caption, design: .monospaced)
            attr.backgroundColor = .gray.opacity(0.2)
        }),
        (#"@(\w+)"#,        { $0.foregroundColor = .blue }),
        (#"(/\w+)"#,        { $0.foregroundColor = .cyan }),
    ]

    struct Span {
        let range: Range<String.Index>
        let display: String
        let apply: (inout AttributedString) -> Void
    }

    var spans: [Span] = []
    for (pattern, style) in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        let nsRange = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: nsRange) {
            guard let fullRange = Range(match.range, in: text) else { continue }
            let displayRange = match.numberOfRanges > 1
                ? Range(match.range(at: 1), in: text) ?? fullRange
                : fullRange
            if spans.contains(where: { $0.range.overlaps(fullRange) }) { continue }
            spans.append(Span(range: fullRange, display: String(text[displayRange]), apply: style))
        }
    }
    spans.sort { $0.range.lowerBound < $1.range.lowerBound }

    var result = AttributedString()
    var cursor = text.startIndex
    for span in spans {
        if cursor < span.range.lowerBound {
            result.append(AttributedString(String(text[cursor..<span.range.lowerBound])))
        }
        var attr = AttributedString(span.display)
        span.apply(&attr)
        result.append(attr)
        cursor = span.range.upperBound
    }
    if cursor < text.endIndex {
        result.append(AttributedString(String(text[cursor...])))
    }
    return result
}
