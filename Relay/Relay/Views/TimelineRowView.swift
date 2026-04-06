import SwiftUI

// MARK: - Timeline Row

struct TimelineRow: View {
    let message: ChatMessage
    let status: ActionStatus
    let showLine: Bool
    var outputText: String? = nil

    private var dotColor: Color {
        if message.isError { return .white.opacity(0.6) }
        if message.role == .action || message.role == .output {
            switch status {
            case .success: return .white.opacity(0.6)
            case .failure: return .white.opacity(0.45)
            case .pending: return .white.opacity(0.25)
            case .neutral: return .white.opacity(0.2)
            }
        }
        if message.role == .user { return .white.opacity(0.5) }
        return .white.opacity(0.15)
    }

    private var dotSize: CGFloat {
        message.role == .action ? 5 : 4
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Timeline column
            VStack(spacing: 0) {
                Circle()
                    .fill(dotColor)
                    .frame(width: dotSize, height: dotSize)
                    .padding(.top, message.role == .action ? 14 : 12)

                if showLine {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 0.5)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 8)

            // Content
            messageContent
                .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(.callout, design: .rounded, weight: .regular))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .foregroundStyle(.white.opacity(0.95))
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                            )
                    )
            }

        case .output:
            OutputBlock(text: message.text)

        case .assistant:
            MarkdownTextView(text: message.text)
                .padding(.top, 2)

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

// MARK: - Action Card

struct ActionCard: View {
    let message: ChatMessage
    let status: ActionStatus

    private var statusAccent: Color {
        switch status {
        case .success: return .white.opacity(0.15)
        case .failure: return .white.opacity(0.1)
        case .pending: return .white.opacity(0.06)
        case .neutral: return .white.opacity(0.06)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: message.actionKind.iconName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 18, height: 18)

            Text(message.actionDisplayText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(2)

            Spacer(minLength: 0)

            // Status dot
            Circle()
                .fill(statusDotColor)
                .frame(width: 5, height: 5)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .opacity(0.6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(statusAccent, lineWidth: 0.5)
        )
    }

    private var statusDotColor: Color {
        switch status {
        case .success: return .white.opacity(0.45)
        case .failure: return .white.opacity(0.3)
        case .pending: return .white.opacity(0.15)
        case .neutral: return .clear
        }
    }
}

// MARK: - Bash Card (IN/OUT terminal style)

struct BashCard: View {
    let message: ChatMessage
    let status: ActionStatus
    var outputText: String? = nil

    /// Extract just the command from "Ran: <command>"
    private var commandText: String {
        let t = message.text
        if let range = t.range(of: "Ran: ") {
            return String(t[range.upperBound...])
        }
        if let range = t.range(of: "Restarted bash") {
            return String(t[range.lowerBound...])
        }
        return message.actionDisplayText
    }

    private var statusDotColor: Color {
        switch status {
        case .success: return .green.opacity(0.8)
        case .failure: return .red.opacity(0.7)
        case .pending: return .white.opacity(0.3)
        case .neutral: return .white.opacity(0.2)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 6, height: 6)

                Text("Bash")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            // IN/OUT block
            VStack(alignment: .leading, spacing: 0) {
                // IN row
                HStack(alignment: .top, spacing: 0) {
                    Text("IN")
                        .font(.system(.caption2, design: .monospaced, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(width: 36, alignment: .leading)

                    Text(commandText)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                // OUT row (if output exists)
                if let output = outputText, !output.isEmpty {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 0.5)

                    HStack(alignment: .top, spacing: 0) {
                        Text("OUT")
                            .font(.system(.caption2, design: .monospaced, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.25))
                            .frame(width: 36, alignment: .leading)

                        Text(output)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(8)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.3))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .opacity(0.7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }
}

// MARK: - Screenshot Card (click to expand)

struct ScreenshotCard: View {
    let status: ActionStatus
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "camera")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))

                    Text("Took screenshot")
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))

                    Spacer(minLength: 0)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            // Expanded screenshot
            if isExpanded {
                Group {
                    if let img = NSImage(named: "sequoia") {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        // Placeholder when image not bundled
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                            .frame(height: 160)
                            .overlay(
                                VStack(spacing: 6) {
                                    Image(systemName: "photo")
                                        .font(.system(size: 24, weight: .light))
                                        .foregroundStyle(.white.opacity(0.15))
                                    Text("Screenshot")
                                        .font(.system(.caption2, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.15))
                                }
                            )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .opacity(0.6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - Thinking Content (collapsible)

struct ThinkingContent: View {
    let message: ChatMessage
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .medium))
                    Text("Thinking")
                        .font(.system(.caption2, design: .rounded))
                    Spacer()
                }
                .foregroundStyle(.white.opacity(0.3))
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(message.text)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                    .lineSpacing(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .opacity(0.4)
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Error / System Content

struct ErrorOrSystemContent: View {
    let message: ChatMessage

    var body: some View {
        if message.isError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                Text(message.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .opacity(0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
        } else {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.3))
                Text(message.text)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Thinking Timeline Row (at bottom of list)

struct ThinkingTimelineRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                PulsingDot()
                    .padding(.top, 10)
            }
            .frame(width: 8)

            HStack(spacing: 8) {
                PanelThinkingDots()
                Text("Thinking")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.white.opacity(0.25))
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Pulsing Dot

struct PulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(Color.white.opacity(isPulsing ? 0.5 : 0.15))
            .frame(width: 4, height: 4)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

// MARK: - Panel Thinking Dots

struct PanelThinkingDots: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.white.opacity(phase == i ? 0.55 : 0.15))
                    .frame(width: 3, height: 3)
                    .animation(.easeInOut(duration: 0.5), value: phase)
            }
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                phase = (phase + 1) % 3
            }
        }
    }
}

// MARK: - Output Block (collapsible bash output)

struct OutputBlock: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 7, weight: .medium))
                    Text("Output")
                        .font(.system(.caption2, design: .rounded))
                    Text("\(text.components(separatedBy: "\n").count) lines")
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
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .opacity(0.4)
                )
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Plan Revised Indicator

struct PlanRevisedIndicator: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 10, weight: .regular))
            Text("Plan revised")
                .font(.system(.caption2, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.2))
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Plan Checklist

struct PlanChecklist: View {
    let steps: [PlanStep]
    var version: Int = 1

    private var completedCount: Int {
        steps.filter(\.isCompleted).count
    }

    /// The step explicitly marked as active by the backend
    private var activeStepId: Int? {
        steps.first(where: { $0.status == .active })?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                Text("Plan v\(version)")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text("\(completedCount)/\(steps.count)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }

            ForEach(steps) { step in
                let isActive = step.id == activeStepId
                HStack(alignment: .top, spacing: 10) {
                    if step.status == .completed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.white.opacity(0.45))
                    } else if step.status == .failed {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.red.opacity(0.6))
                    } else if isActive {
                        PlanStepSpinner()
                    } else {
                        Image(systemName: "circle")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.white.opacity(0.18))
                    }

                    Text(step.title)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(
                            step.isCompleted ? .white.opacity(0.3) :
                            step.status == .failed ? .red.opacity(0.5) :
                            isActive ? .white.opacity(0.8) :
                            .white.opacity(0.5)
                        )
                        .strikethrough(step.isCompleted, color: .white.opacity(0.12))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .opacity(0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - Plan Step Spinner

private struct PlanStepSpinner: View {
    @State private var isAnimating = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.65)
            .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: isAnimating)
            .onAppear { isAnimating = true }
    }
}

// MARK: - Preview: All Component Types

#Preview("All Chat Components") {
    let sampleMessages: [(ChatMessage, ActionStatus, String?)] = [
        // 1. User message
        (ChatMessage(role: .user, text: "Can you navigate to the Ramp dashboard and download the Q4 report?"), .neutral, nil),

        // 2. Assistant message with rich markdown
        (ChatMessage(role: .assistant, text: "I'll create a markdown file explaining why Ramp is a great product. Let me propose the plan:\n\n## Plan\n1. Create a markdown file with a compelling explanation of why Ramp is a great product\n2. Keep it under 200 words\n3. Cover key benefits like expense management, automation, and financial control\n4. Save it to `/tmp/ramp_product.md`\n5. Add the path to `/tmp/relay_outputs.txt` for retrieval\n\nDoes this work for you? Should I proceed?"), .neutral, nil),

        // 3. Thinking block
        (ChatMessage(role: .thinking, text: "I need to navigate to the Ramp dashboard. First I'll take a screenshot to see the current state, then click on the address bar and type the URL. I should look for the Q4 report in the downloads or reports section."), .neutral, nil),

        // 4. Action: click (success)
        (ChatMessage(role: .action, text: "Clicked at (450, 320)"), .success, nil),

        // 5. Action: keyboard (success)
        (ChatMessage(role: .action, text: "Typed https://app.ramp.com/dashboard"), .success, nil),

        // 6. Action: bash with output (success)
        (ChatMessage(role: .action, text: "Ran: curl -s https://api.ramp.com/v1/reports"), .success, "HTTP/1.1 200 OK\nContent-Type: application/json\n\n{\"status\": \"success\", \"count\": 3}"),

        // 7. Action: bash without output (failure)
        (ChatMessage(role: .action, text: "Ran: npm run build"), .failure, "Error: Module not found\nexit code 1"),

        // 8. Action: screenshot (pending)
        (ChatMessage(role: .action, text: "Captured screenshot"), .pending, nil),

        // 9. Action: editor (success)
        (ChatMessage(role: .action, text: "str_replace: config.json — updated API endpoint"), .success, nil),

        // 10. Action: scroll (neutral)
        (ChatMessage(role: .action, text: "Scrolled down at (640, 400)"), .neutral, nil),

        // 11. Action: other / wait (neutral)
        (ChatMessage(role: .action, text: "Waited 2 seconds"), .neutral, nil),

        // 12. Action: drag (success)
        (ChatMessage(role: .action, text: "Dragged from (100, 200) to (300, 400)"), .success, nil),

        // 13. Output block (standalone)
        (ChatMessage(role: .output, text: "HTTP/1.1 200 OK\nContent-Type: application/json\n\n{\n  \"status\": \"success\",\n  \"report\": \"Q4-2025.pdf\",\n  \"size\": \"2.4MB\"\n}"), .neutral, nil),

        // 14. Assistant follow-up with code block and list
        (ChatMessage(role: .assistant, text: "The report downloaded successfully. Here's what I found:\n\n- **Q4-2025.pdf** in the downloads folder\n- File size: *2.4 MB*\n- Format: `application/pdf`\n\n```\ncurl -s https://api.ramp.com/reports/q4\n# HTTP 200 OK\n```\n\nLet me know if you need anything else!"), .neutral, nil),

        // 15. System info message
        (ChatMessage(role: .system, text: "Container ready — connected to session abc-123"), .neutral, nil),

        // 16. Error message
        (ChatMessage(role: .system, text: "Connection lost: WebSocket closed unexpectedly", isError: true), .neutral, nil),
    ]

    ScrollView {
        VStack(spacing: 0) {
            // Plan checklist
            PlanChecklist(steps: [
                PlanStep(id: 1, shortDescription: "Open Chrome and navigate to Ramp dashboard", detailedInstructions: "", suggestedTools: ["computer"], status: .completed),
                PlanStep(id: 2, shortDescription: "Log in with provided credentials", detailedInstructions: "", suggestedTools: ["computer"], status: .completed),
                PlanStep(id: 3, shortDescription: "Navigate to Reports section", detailedInstructions: "", suggestedTools: ["computer"], status: .active),
                PlanStep(id: 4, shortDescription: "Download Q4 report as PDF", detailedInstructions: "", suggestedTools: ["computer"], status: .pending),
                PlanStep(id: 5, shortDescription: "Verify file contents", detailedInstructions: "", suggestedTools: ["bash"], status: .pending),
            ])
            .padding(.bottom, 16)

            // All message types
            ForEach(Array(sampleMessages.enumerated()), id: \.offset) { i, triple in
                let isLast = i == sampleMessages.count - 1
                TimelineRow(
                    message: triple.0,
                    status: triple.1,
                    showLine: !isLast,
                    outputText: triple.2
                )
            }

            // Thinking indicator at bottom
            ThinkingTimelineRow()
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
    }
    .background(Color(white: 0.05))
    .preferredColorScheme(.dark)
}
