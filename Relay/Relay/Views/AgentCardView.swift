import SwiftUI

struct AgentCardView: View {
    let agent: BrowserAgent
    var isSelected: Bool = false
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                // Thumbnail area with play button overlay
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(white: 0.1))

                    // Fake desktop lines
                    VStack(spacing: 4) {
                        HStack(spacing: 3) {
                            ForEach(0..<3, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.white.opacity(0.03))
                                    .frame(height: 50)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 10)

                        Spacer()
                    }

                    // Play button overlay
                    Circle()
                        .fill(Color.black.opacity(0.5))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.7))
                                .offset(x: 2)
                        )
                }
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // Info area
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(agent.agentName)
                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.white)

                        Text(agent.currentTaskName)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Circle()
                            .fill(agent.relayStatus.dotColor)
                            .frame(width: 8, height: 8)
                            .padding(.top, 3)

                        Text(agent.formattedCost)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isSelected ? Color.blue : Color.white.opacity(0.06),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .shadow(color: isSelected ? Color.blue.opacity(0.5) : .clear, radius: 12, x: 0, y: 0)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}
