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

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(messages) { msg in
                            ChatBubble(message: msg)
                                .id(msg.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: messages.last?.text) { _, _ in
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
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

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        inputText = ""
        Task { try? await store.sendMessage(to: agent, text: text) }
    }
}

// MARK: - Chat Bubble

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 3) {
                if message.role == .system {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right.circle")
                            .font(.caption2)
                            .foregroundStyle(.cyan.opacity(0.5))
                        Text(message.text)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(message.text)
                        .font(.system(.callout, design: .default))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(message.role == .user
                                      ? Color.accentColor.opacity(0.8)
                                      : Color.white.opacity(0.06))
                        )
                        .foregroundStyle(message.role == .user ? .white : .white.opacity(0.8))

                    Text(message.timestamp, style: .time)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.15))
                }
            }

            if message.role != .user && message.role != .system { Spacer(minLength: 40) }
        }
    }
}
