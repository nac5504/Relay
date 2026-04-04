import SwiftUI

struct MainChatView: View {
    let store: MockAgentStore
    @State private var inputText = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(store.mainChatMessages.enumerated()), id: \.element.id) { i, msg in
                            let prev = i > 0 ? store.mainChatMessages[i - 1] : nil
                            let isFirstInGroup = prev == nil || prev?.role != msg.role || prev?.agentName != msg.agentName
                            let avatarURL = msg.agentName.flatMap { name in
                                store.agents.first(where: { $0.agentName == name })?.avatarURL
                            }
                            MessageRow(message: msg, isFirstInGroup: isFirstInGroup, agentAvatarURL: avatarURL)
                                .id(msg.id)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                }
                .onChange(of: store.mainChatMessages.count) { _, _ in
                    if let last = store.mainChatMessages.last {
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

// MARK: - Message Row

private struct MessageRow: View {
    let message: ChatMessage
    let isFirstInGroup: Bool
    var agentAvatarURL: URL? = nil

    var body: some View {
        if message.role == .user {
            userRow
        } else if message.isLoading {
            thinkingRow
        } else {
            assistantRow
        }
    }

    private var userRow: some View {
        HStack {
            Spacer(minLength: 60)
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
        .padding(.top, isFirstInGroup ? 10 : 2)
    }

    private var thinkingRow: some View {
        HStack(alignment: .top, spacing: 10) {
            if agentAvatarURL != nil {
                CachedAvatarView(url: agentAvatarURL, size: 24)
            } else {
                Image(systemName: "sparkle")
                    .font(.system(size: 14))
                    .foregroundStyle(.cyan)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.06)))
            }

            VStack(alignment: .leading, spacing: 2) {
                if let name = message.agentName {
                    Text(name)
                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                ThinkingDotsView()
            }

            Spacer(minLength: 40)
        }
        .padding(.top, 10)
    }

    private var assistantRow: some View {
        HStack(alignment: .top, spacing: 10) {
            if isFirstInGroup {
                if agentAvatarURL != nil {
                    CachedAvatarView(url: agentAvatarURL, size: 24)
                } else {
                    Image(systemName: "sparkle")
                        .font(.system(size: 14))
                        .foregroundStyle(.cyan)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
            } else {
                Color.clear.frame(width: 24, height: 24)
            }

            VStack(alignment: .leading, spacing: 2) {
                if isFirstInGroup, let name = message.agentName {
                    Text(name)
                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Text(coloredText(message.text))
                    .font(.system(.callout, design: .default))
                    .foregroundStyle(.white.opacity(0.8))
                    .textSelection(.enabled)
            }

            Spacer(minLength: 40)
        }
        .padding(.top, isFirstInGroup ? 10 : 2)
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

func coloredText(_ text: String) -> AttributedString {
    // Order matters: bold before italic so ** is matched first
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

    // Collect all styled spans, earliest first
    var spans: [Span] = []
    for (pattern, style) in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        let nsRange = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: nsRange) {
            guard let fullRange = Range(match.range, in: text) else { continue }
            // Use capture group 1 for display text (strips markers), fall back to full match
            let displayRange = match.numberOfRanges > 1
                ? Range(match.range(at: 1), in: text) ?? fullRange
                : fullRange
            // Skip if overlapping with an earlier span
            if spans.contains(where: { $0.range.overlaps(fullRange) }) { continue }
            spans.append(Span(range: fullRange, display: String(text[displayRange]), apply: style))
        }
    }
    spans.sort { $0.range.lowerBound < $1.range.lowerBound }

    // Build attributed string
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
