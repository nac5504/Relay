import SwiftUI
import AppKit

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

    /// A vertical slice of the main chat. Messages preceding the first
    /// approved plan render in a `.planning` section with no pinned header;
    /// everything from an approved `.plan` message onward renders in an
    /// `.acting` section whose header is that plan's PlanChecklist, pinned
    /// to the top of the scroll view while its execution rows scroll below.
    private struct ChatSection: Identifiable {
        enum Kind { case planning, acting }
        let id: String
        let kind: Kind
        let header: ChatMessage?
        let items: [Item]

        struct Item: Identifiable {
            let index: Int
            let message: ChatMessage
            var id: UUID { message.id }
        }
    }

    /// Splits the supplied `messages` snapshot into planning/acting sections.
    /// Only `.plan` messages whose owning agent has `planComplete == true`
    /// (i.e. the user has approved the plan) become section boundaries.
    /// Intermediate plan revisions stay inline as no-op rows so they don't
    /// pin a header. Takes `messages` as a parameter so callers can guarantee
    /// the indices stamped on each `Item` match the array later passed to
    /// `rowView` — re-reading `store.filteredMainChatMessages` separately
    /// would race with focus changes and crash with stale indices.
    private func sections(from messages: [ChatMessage]) -> [ChatSection] {
        var result: [ChatSection] = []
        var currentKind: ChatSection.Kind = .planning
        var currentHeader: ChatMessage? = nil
        var currentItems: [ChatSection.Item] = []

        func flush() {
            guard currentHeader != nil || !currentItems.isEmpty else { return }
            let id = currentHeader.map { "acting-\($0.id.uuidString)" }
                ?? "planning-\(result.count)"
            result.append(ChatSection(
                id: id,
                kind: currentKind,
                header: currentHeader,
                items: currentItems
            ))
        }

        for (i, msg) in messages.enumerated() {
            let isFinalizedPlan = msg.role == .plan
                && (agentForPlanMessage(msg)?.planComplete ?? false)
            if isFinalizedPlan {
                flush()
                currentKind = .acting
                currentHeader = msg
                currentItems = []
            } else {
                currentItems.append(ChatSection.Item(index: i, message: msg))
            }
        }
        flush()

        return result
    }

    /// Scrolls to the bottom of the chat. Picks the target based on what is
    /// actually rendered: the thinking row when an agent is working and the
    /// last message isn't from the user, otherwise the last message itself.
    /// Deferred to the next runloop tick so the LazyVStack has time to lay
    /// out a freshly-inserted row before `scrollTo` runs.
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let target: AnyHashable? = {
            if hasWorkingAgent && store.filteredMainChatMessages.last?.role != .user {
                return AnyHashable("main-thinking")
            }
            return store.filteredMainChatMessages.last.map { AnyHashable($0.id) }
        }()
        guard let target else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation { proxy.scrollTo(target, anchor: .bottom) }
            } else {
                proxy.scrollTo(target, anchor: .bottom)
            }
        }
    }

    var body: some View {
        // Snapshot the filtered messages exactly once per body evaluation so
        // every index we hand to `rowView` is anchored to the same array.
        // `filteredMainChatMessages` is computed and shrinks the moment a
        // user focuses an agent — re-reading it from inside `rowView` while
        // a stale `item.index` is in flight is what was crashing the LazyVStack.
        let messages = store.filteredMainChatMessages
        let chatSections = sections(from: messages)
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(chatSections) { section in
                            if let header = section.header {
                                // Acting section: PlanChecklist pins to the top
                                // while its execution rows scroll underneath.
                                Section {
                                    ForEach(section.items) { item in
                                        rowView(for: item.message, at: item.index, in: messages)
                                            .padding(.horizontal, 16)
                                    }
                                } header: {
                                    planStickyHeader(for: header)
                                }
                            } else {
                                // Planning section: no sticky header, render
                                // items inline so SwiftUI's pinning machinery
                                // isn't asked to track an empty header slot.
                                ForEach(section.items) { item in
                                    rowView(for: item.message, at: item.index, in: messages)
                                        .padding(.horizontal, 16)
                                }
                            }
                        }

                        if hasWorkingAgent && messages.last?.role != .user {
                            MainThinkingRow()
                                .padding(.horizontal, 16)
                                .id("main-thinking")
                        }
                    }
                    .padding(.bottom, 12)
                }
                .onChange(of: store.filteredMainChatMessages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: hasWorkingAgent) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: store.filteredMainChatMessages.last?.text) { _, _ in
                    scrollToBottom(proxy)
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

    /// Pinned header rendered at the top of each acting section. An opaque
    /// blurred backdrop keeps rows scrolling underneath it from bleeding
    /// through the PlanChecklist's translucent card.
    @ViewBuilder
    private func planStickyHeader(for message: ChatMessage) -> some View {
        let planAgent = agentForPlanMessage(message)
        VStack(alignment: .leading, spacing: 8) {
            Text("Final Plan")
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .textCase(.uppercase)
                .tracking(1.0)
                .padding(.horizontal, 20)

            PlanChecklist(
                steps: planAgent?.planSteps ?? [],
                version: planAgent?.planVersion ?? 1
            )
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(red: 0x28/255, green: 0x2A/255, blue: 0x28/255))
            )
            .padding(.horizontal, 16)
        }
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(message.id)
    }

    /// Renders a single timeline row. Mirrors the rules from the original
    /// inline loop (bash/output merging, first-for-agent avatar header,
    /// action status colouring) using the row's original chronological
    /// index inside the supplied `messages` snapshot. The snapshot is passed
    /// in (not re-read from `store`) so the index can never refer to a
    /// different array than the one `sections(from:)` stamped it against.
    @ViewBuilder
    private func rowView(for msg: ChatMessage, at i: Int, in messages: [ChatMessage]) -> some View {
        if !messages.indices.contains(i) {
            // Stale index from a row LazyVStack is tearing down after a
            // focus change shrank the array — render nothing.
            EmptyView()
        } else if msg.role == .output && i > 0 && messages[i - 1].role == .action && messages[i - 1].actionKind == .bash {
            // Merged into the preceding bash card
            EmptyView()
        } else if msg.role == .planRevised {
            PlanRevisedIndicator()
                .padding(.bottom, 14)
                .id(msg.id)
        } else if msg.role == .plan {
            let planAgent = agentForPlanMessage(msg)
            HStack(alignment: .top, spacing: 14) {
                // Timeline gutter — top stub, dot, bottom line. Drawn
                // continuously so the line from the previous agent row flows
                // through the plan dot and into the next agent row without
                // gaps. Aligns with `MainTimelineRow`'s gutter pattern.
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: 1, height: 14)
                    Circle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 5, height: 5)
                    Rectangle()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .padding(.top, 2)
                }
                .frame(width: 8)

                // Bottom padding lives inside the HStack on the content side
                // so the HStack's height (and therefore the gutter's bottom
                // line) extends through the inter-row gap. Putting it on the
                // outer HStack would leave a 14-pt gap below the line.
                PlanChecklist(
                    steps: planAgent?.planSteps ?? [],
                    version: planAgent?.planVersion ?? 1
                )
                .padding(.bottom, 14)
            }
            .id(msg.id)
        } else {
            let isLast = i == messages.count - 1 && !hasWorkingAgent
            let status = actionStatus(at: i, in: messages)
            let avatarURL = msg.agentName.flatMap { name in
                store.agents.first(where: { $0.agentName == name })?.avatarURL
            }
            let isFirstForAgent: Bool = {
                guard let name = msg.agentName else { return false }
                if i == 0 { return true }
                let prev = messages[i - 1]
                // User messages are breaks — the next agent message always
                // starts a fresh "string" and should re-show the header.
                if prev.role == .user { return true }
                return prev.agentName != name
            }()
            let bashOutput: String? = (msg.role == .action && msg.actionKind == .bash && i + 1 < messages.count && messages[i + 1].role == .output) ? messages[i + 1].text : nil
            // User messages are breaks in the agent timeline — no line should
            // reach into or out of them.
            let prevIsUser = i > 0 && messages[i - 1].role == .user
            let nextIsUser = i + 1 < messages.count && messages[i + 1].role == .user
            let breaksBefore = msg.role == .user || prevIsUser
            let breaksAfter = msg.role == .user || nextIsUser
            MainTimelineRow(
                message: msg,
                isFirstForAgent: isFirstForAgent,
                showLine: !isLast && !breaksAfter,
                showTopLine: i != 0 && !breaksBefore,
                status: status,
                agentAvatarURL: avatarURL,
                agentColor: agentLineColor(for: msg.agentName),
                outputText: bashOutput
            )
            .id(msg.id)
        }
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
    let isFirstForAgent: Bool
    let showLine: Bool
    let showTopLine: Bool
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
        return .white.opacity(0.22)
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
                if showTopLine {
                    Rectangle()
                        .fill(lineColor)
                        .frame(width: 1, height: topLineHeight)
                } else {
                    Color.clear.frame(width: 1, height: topLineHeight)
                }

                if message.role != .user {
                    Circle()
                        .fill(dotColor)
                        .frame(width: dotSize, height: dotSize)
                }

                if showLine {
                    Rectangle()
                        .fill(lineColor)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 8)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                // Agent name only on the most recent message from this agent
                if isFirstForAgent && message.role != .user, let name = message.agentName {
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

        case .files:
            InlineFileLinks(files: message.files ?? [], dir: message.filesDir)

        case .plan, .planRevised:
            EmptyView() // Handled inline before reaching this view
        }
    }
}

// MARK: - Inline File Hyperlinks

/// A vertical list of file names rendered as clickable hyperlinks. Each row
/// reveals the file in Finder via NSWorkspace. Styled like a real hyperlink:
/// cyan, underlined on hover, with a small file-type icon leading.
struct InlineFileLinks: View {
    let files: [String]
    let dir: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(files, id: \.self) { file in
                FileHyperlink(
                    filename: file,
                    fullPath: dir.map { joinPath($0, file) }
                )
            }
        }
        .padding(.top, 2)
    }

    private func joinPath(_ dir: String, _ file: String) -> String {
        dir.hasSuffix("/") ? dir + file : dir + "/" + file
    }
}

private struct FileHyperlink: View {
    let filename: String
    let fullPath: String?
    @State private var isHovering = false

    private var iconName: String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext.fill"
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo.fill"
        case "csv", "xlsx", "xls": return "tablecells.fill"
        case "txt", "md", "log": return "doc.text.fill"
        case "json", "yaml", "yml", "toml": return "curlybraces"
        case "html", "htm": return "globe"
        case "zip", "tar", "gz", "7z": return "archivebox.fill"
        case "mp4", "mov", "avi", "webm": return "film.fill"
        case "mp3", "wav", "m4a": return "waveform"
        case "py", "js", "ts", "swift", "go", "rs", "java", "c", "cpp", "h":
            return "chevron.left.forwardslash.chevron.right"
        default: return "doc.fill"
        }
    }

    var body: some View {
        Button(action: reveal) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.caption)
                    .foregroundStyle(.cyan.opacity(0.85))

                Text(filename)
                    .font(.system(.callout, design: .monospaced, weight: .medium))
                    .foregroundStyle(.cyan)
                    .underline(true, color: .cyan.opacity(isHovering ? 0.95 : 0.45))

                Image(systemName: "arrow.up.forward.square")
                    .font(.caption2)
                    .foregroundStyle(.cyan.opacity(isHovering ? 0.9 : 0.5))
            }
        }
        .buttonStyle(.plain)
        .disabled(fullPath == nil)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help(fullPath.map { "Reveal in Finder: \($0)" } ?? "\(filename) (path unavailable)")
    }

    private func reveal() {
        guard let path = fullPath else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Main Thinking Row

private struct MainThinkingRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 1, height: 8)
                PulsingDot()
            }
            .frame(width: 8)

            HStack(spacing: 8) {
                PanelThinkingDots()
                Text("Thinking")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.white.opacity(0.25))
            }

            Spacer()
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
