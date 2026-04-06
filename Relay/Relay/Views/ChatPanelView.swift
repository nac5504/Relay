import SwiftUI

struct ChatPanelView: View {
    let agent: BrowserAgent
    let store: AgentStore
    var onClose: () -> Void
    @State private var inputText = ""
    @State private var showVoicePermissionAlert = false
    @AppStorage("voice_enabled") private var voiceEnabled = true
    private let voiceManager = VoiceInputManager.shared

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

    /// Show approve/modify buttons on the current plan during planning
    private var showPlanActions: Bool {
        isPlanningPhase && !agent.planComplete && !agent.planSteps.isEmpty
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

            // Messages with timeline — plans rendered inline at their position
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { i, msg in
                            // Skip output messages that were merged into a preceding bash card
                            if msg.role == .output && i > 0 && messages[i - 1].role == .action && messages[i - 1].actionKind == .bash {
                                EmptyView()
                            } else if msg.role == .assistant && msg.text.contains("<plan/>") {
                                // Assistant message with embedded plan — split on marker
                                let parts = msg.text.components(separatedBy: "<plan/>")
                                let snapshot = agent.planSnapshots[msg.id]
                                let isCurrentPlan = msg.id == agent.currentPlanMessageId
                                VStack(alignment: .leading, spacing: 8) {
                                    if let before = parts.first, !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        MarkdownTextView(text: before.trimmingCharacters(in: .whitespacesAndNewlines))
                                    }
                                    if isCurrentPlan {
                                        PlanChecklist(
                                            steps: snapshot?.steps ?? agent.planSteps,
                                            version: snapshot?.version ?? agent.planVersion
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
                                let isLast = i == messages.count - 1 && !isThinking
                                let status = actionStatus(at: i, in: messages)
                                let bashOutput: String? = (msg.role == .action && msg.actionKind == .bash && i + 1 < messages.count && messages[i + 1].role == .output) ? messages[i + 1].text : nil
                                TimelineRow(
                                    message: msg,
                                    status: status,
                                    showLine: !isLast,
                                    outputText: bashOutput
                                )
                                .id(msg.id)
                            }
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

            // Approve plan banner
            if showPlanActions {
                Button(action: approvePlan) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text("Approve Plan v\(agent.planVersion)")
                            .font(.system(.caption, design: .monospaced, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        Image(systemName: "return")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.06))
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Listening indicator
            if voiceManager.isListening {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 5, height: 5)
                        .shadow(color: .red.opacity(0.6), radius: 3)
                    Text("Listening...")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.04))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Input bar
            HStack(spacing: 8) {
                if voiceEnabled {
                    VoiceWaveformButton(
                        isListening: voiceManager.isListening,
                        audioLevel: voiceManager.audioLevel,
                        action: { toggleVoice() },
                        compact: true
                    )
                }

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
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(voiceManager.isListening ? Color.red.opacity(0.25) : Color.clear, lineWidth: 1)
                        )
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
        .alert("Microphone & Speech Access", isPresented: $showVoicePermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(voiceManager.error ?? "Relay needs microphone and speech recognition access. Please enable them in System Settings > Privacy & Security.")
        }
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

    private func approvePlan() {
        Task { try? await store.sendMessage(to: agent, text: "go") }
    }

    private func toggleVoice() {
        if voiceManager.isListening {
            voiceManager.stopListening()
        } else {
            Task {
                guard await voiceManager.requestPermissions() else {
                    showVoicePermissionAlert = true
                    return
                }
                voiceManager.startListening(
                    onUpdate: { processed in self.inputText = processed },
                    onSend: { self.sendMessage() }
                )
            }
        }
    }
}

// Timeline components extracted to TimelineRowView.swift
