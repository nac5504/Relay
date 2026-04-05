import SwiftUI

struct ChatPanelView: View {
    let agent: BrowserAgent
    let store: AgentStore
    var onClose: () -> Void
    @State private var inputText = ""

    private var isPlanningPhase: Bool {
        agent.relayStatus.isPlanningPhase
    }

    private var messages: [ChatMessage] {
        agent.activeMessages
    }

    private var isThinking: Bool {
        agent.relayStatus == .working
            && messages.last?.role != .user
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isPlanningPhase ? "Plan" : "Chat")
                    .font(.system(.headline, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(white: 0.05))

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            // Status banner
            if isPlanningPhase && !agent.planComplete {
                HStack(spacing: 6) {
                    if agent.relayStatus == .starting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                    Text(agent.relayStatus == .starting ? "Booting container..." : "Container ready")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cyan.opacity(0.06))
            }

            // Waiting banner
            if agent.waitingForInput && !isPlanningPhase {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill")
                        .font(.caption)
                    Text("Waiting for your input")
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                }
                .foregroundStyle(.orange)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.orange.opacity(0.08))
            }

            // Messages with timeline
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Task checklist
                        if !agent.planSteps.isEmpty {
                            PlanChecklist(steps: agent.planSteps)
                                .padding(.bottom, 8)
                        }

                        ForEach(Array(messages.enumerated()), id: \.element.id) { i, msg in
                            let isLast = i == messages.count - 1 && !isThinking
                            let status = actionStatus(at: i, in: messages)
                            TimelineRow(
                                message: msg,
                                status: status,
                                showLine: !isLast
                            )
                            .id(msg.id)
                        }

                        // Thinking indicator as timeline row
                        if isThinking {
                            ThinkingTimelineRow()
                                .id("thinking-indicator")
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 12)
                }
                .onChange(of: messages.count) { _, _ in scrollToBottom(proxy) }
                .onChange(of: messages.last?.text) { _, _ in scrollToBottom(proxy) }
                .onChange(of: isThinking) { _, val in
                    if val { withAnimation { proxy.scrollTo("thinking-indicator", anchor: .bottom) } }
                }
            }

            // Output files
            if !agent.outputFiles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("OUTPUT FILES")
                        .font(.system(.caption2, design: .monospaced, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.3))
                        .tracking(1)
                    ForEach(agent.outputFiles, id: \.self) { file in
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(.cyan)
                                .font(.caption)
                            Text(file)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.03))
            }

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            // Pinned agent footer with thinking indicator
            HStack(spacing: 10) {
                CachedAvatarView(url: agent.avatarURL, size: 24)

                Text(agent.agentName)
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))

                Spacer()

                if isThinking {
                    HStack(spacing: 6) {
                        PanelThinkingDots()
                        Text("Thinking...")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                } else if agent.relayStatus == .completed {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text("Done")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                } else if agent.relayStatus == .error {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                        Text("Error")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.red.opacity(0.7))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(white: 0.04))

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            // Input bar
            HStack(spacing: 8) {
                TextField(
                    isPlanningPhase ? "Refine the plan..." : "Send a message...",
                    text: $inputText
                )
                .textFieldStyle(.plain)
                .font(.system(.callout, design: .monospaced))
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.04))
                )
                .foregroundStyle(.white)
                .onSubmit { sendMessage() }

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(
                            inputText.trimmingCharacters(in: .whitespaces).isEmpty
                                ? Color.white.opacity(0.15)
                                : Color.accentColor
                        )
                }
                .buttonStyle(.plain)
                .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
        .background(Color(white: 0.05))
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 1),
            alignment: .leading
        )
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if isThinking {
            withAnimation { proxy.scrollTo("thinking-indicator", anchor: .bottom) }
        } else if let last = messages.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        inputText = ""
        Task { try? await store.sendMessage(to: agent, text: text) }
    }
}

// MARK: - Timeline Row

private struct TimelineRow: View {
    let message: ChatMessage
    let status: ActionStatus
    let showLine: Bool

    private var dotColor: Color {
        if message.isError { return .red }
        if message.role == .action || message.role == .output { return status.dotColor }
        if message.role == .user { return .accentColor.opacity(0.6) }
        return .white.opacity(0.15)
    }

    private var dotSize: CGFloat {
        message.role == .action ? 8 : 6
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Timeline column
            VStack(spacing: 0) {
                Circle()
                    .fill(dotColor)
                    .frame(width: dotSize, height: dotSize)
                    .padding(.top, message.role == .action ? 5 : 6)

                if showLine {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 10)

            // Content
            messageContent
                .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 20)
                Text(message.text)
                    .font(.system(.callout))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.8)))
                    .foregroundStyle(.white)
            }

        case .output:
            OutputBlock(text: message.text)

        case .assistant:
            Text(coloredText(message.text))
                .font(.system(.callout))
                .foregroundStyle(.white.opacity(0.85))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .action:
            ActionCard(message: message, status: status)

        case .thinking:
            ThinkingContent(message: message)

        case .system:
            ErrorOrSystemContent(message: message)
        }
    }
}

// MARK: - Action Card

private struct ActionCard: View {
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

// MARK: - Thinking Content (collapsible)

private struct ThinkingContent: View {
    let message: ChatMessage
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("Thinking...")
                        .font(.system(.caption2, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(0.25))
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(message.text)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.2))
                    .padding(.leading, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Error / System Content

private struct ErrorOrSystemContent: View {
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

// MARK: - Thinking Timeline Row (at bottom of list)

private struct ThinkingTimelineRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Pulsing dot
            VStack(spacing: 0) {
                PulsingDot()
                    .padding(.top, 6)
            }
            .frame(width: 10)

            HStack(spacing: 6) {
                PanelThinkingDots()
            }
            .padding(.top, 2)
        }
    }
}

// MARK: - Pulsing Dot

private struct PulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(Color.cyan.opacity(isPulsing ? 0.6 : 0.2))
            .frame(width: 6, height: 6)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

// MARK: - Panel Thinking Dots

private struct PanelThinkingDots: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.cyan.opacity(phase == i ? 0.8 : 0.25))
                    .frame(width: 4, height: 4)
                    .animation(.easeInOut(duration: 0.4), value: phase)
            }
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                phase = (phase + 1) % 3
            }
        }
    }
}

// MARK: - Output Block (collapsible bash output)

private struct OutputBlock: View {
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

// MARK: - Plan Checklist

struct PlanChecklist: View {
    let steps: [PlanStep]

    private var completedCount: Int {
        steps.filter(\.isCompleted).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.caption)
                    .foregroundStyle(.cyan)
                Text("Plan")
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text("\(completedCount)/\(steps.count)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }

            ForEach(steps) { step in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: step.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(step.isCompleted ? .green : .white.opacity(0.2))

                    Text(step.title)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(step.isCompleted ? .white.opacity(0.3) : .white.opacity(0.6))
                        .strikethrough(step.isCompleted, color: .white.opacity(0.15))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}
