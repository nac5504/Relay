import SwiftUI

struct ChatPanelView: View {
    let agent: BrowserAgent
    let store: AgentStore
    var onClose: () -> Void
    @State private var inputText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Chat")
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

            // Waiting banner
            if agent.waitingForInput {
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
                        ForEach(agent.chatMessages) { msg in
                            ChatBubble(message: msg)
                                .id(msg.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: agent.chatMessages.count) { _, _ in
                    if let last = agent.chatMessages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            // Input bar
            HStack(spacing: 8) {
                TextField("Send a message...", text: $inputText)
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
        Task {
            try? await store.sendMessage(to: agent, text: text)
        }
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
                    Text(message.text)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.2))
                        .frame(maxWidth: .infinity)
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
