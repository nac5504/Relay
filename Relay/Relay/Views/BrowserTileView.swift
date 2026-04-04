import SwiftUI

struct BrowserTileView: View {
    @Bindable var agent: BrowserAgent
    var isMentioned: Bool = false
    var onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if agent.status == .running {
                BrowserStreamView(
                    agent: agent,
                    onFPSUpdate: { fps in
                        agent.fps = fps
                    }
                )
            } else if agent.status == .error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text(agent.errorMessage ?? "Unknown error")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.8))
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Starting \(agent.displayName)...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.8))
            }

            // Overlay controls
            VStack(alignment: .trailing, spacing: 4) {
                // FPS badge
                Text("\(agent.fps, specifier: "%.0f") FPS")
                    .font(.system(.caption, design: .monospaced).bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.7))
                    .foregroundStyle(fpsColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                // Agent name
                Text(agent.displayName)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.7))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                // Close button
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
            .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isMentioned ? Color.blue : borderColor, lineWidth: isMentioned ? 3 : 2)
        )
        .shadow(color: isMentioned ? Color.blue.opacity(0.6) : .clear, radius: 16, x: 0, y: 0)
        .animation(.easeInOut(duration: 0.25), value: isMentioned)
    }

    private var fpsColor: Color {
        if agent.fps >= 24 { return .green }
        if agent.fps >= 15 { return .yellow }
        return .red
    }

    private var borderColor: Color {
        switch agent.status {
        case .running: .green.opacity(0.5)
        case .starting: .orange.opacity(0.5)
        case .error: .red.opacity(0.5)
        default: .gray.opacity(0.3)
        }
    }
}
