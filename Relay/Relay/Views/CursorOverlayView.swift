import SwiftUI

/// Animated overlay that shows the agent's cursor position and click ripples
/// on top of the browser stream.
struct CursorOverlayView: View {
    @Bindable var agent: BrowserAgent
    @State private var ripples: [CursorRipple] = []

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Ripple animations for clicks
                ForEach(ripples) { ripple in
                    RippleEffect(ripple: ripple, geo: geo)
                }

                // Cursor indicator
                if agent.cursorVisible, let pos = agent.cursorPosition {
                    let pt = CGPoint(x: pos.x * geo.size.width, y: pos.y * geo.size.height)
                    CursorIndicator(actionType: agent.cursorActionType ?? "unknown")
                        .position(pt)
                        .transition(.opacity)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: pos.x)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: pos.y)
                }
            }
            .onChange(of: agent.cursorTimestamp) { _, _ in
                spawnRipple()
            }
        }
        .allowsHitTesting(false) // pass through all mouse events to noVNC
    }

    private func spawnRipple() {
        guard let pos = agent.cursorPosition else { return }
        let actionType = agent.cursorActionType ?? "unknown"

        // Only ripple for click-type actions
        let clickActions = ["left_click", "right_click", "double_click", "triple_click", "left_click_drag"]
        guard clickActions.contains(actionType) else { return }

        let ripple = CursorRipple(position: pos, actionType: actionType)
        withAnimation { ripples.append(ripple) }

        // Remove ripple after animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation { ripples.removeAll { $0.id == ripple.id } }
        }
    }
}

// MARK: - Cursor Indicator

private struct CursorIndicator: View {
    let actionType: String
    @State private var pulse = false

    var body: some View {
        ZStack {
            // Outer glow
            Circle()
                .fill(accentColor.opacity(0.15))
                .frame(width: 32, height: 32)
                .scaleEffect(pulse ? 1.3 : 1.0)

            // Middle ring
            Circle()
                .stroke(accentColor.opacity(0.6), lineWidth: 2)
                .frame(width: 20, height: 20)

            // Center dot
            Circle()
                .fill(accentColor)
                .frame(width: 8, height: 8)
                .shadow(color: accentColor, radius: 4)

            // Crosshair lines
            if isClickAction {
                Group {
                    Rectangle().frame(width: 1, height: 28)
                    Rectangle().frame(width: 28, height: 1)
                }
                .foregroundStyle(accentColor.opacity(0.4))
            }

            // Scroll indicator arrows
            if actionType == "scroll" {
                VStack(spacing: 14) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(accentColor.opacity(0.6))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var isClickAction: Bool {
        ["left_click", "right_click", "double_click", "triple_click"].contains(actionType)
    }

    private var accentColor: Color {
        switch actionType {
        case "left_click", "double_click", "triple_click":
            return .cyan
        case "right_click":
            return .orange
        case "scroll":
            return .yellow
        case "mouse_move":
            return .white.opacity(0.6)
        case "left_click_drag":
            return .purple
        case "type", "key":
            return .green
        default:
            return .cyan
        }
    }
}

// MARK: - Ripple

struct CursorRipple: Identifiable {
    let id = UUID()
    let position: CGPoint   // normalized 0…1
    let actionType: String
    let createdAt = Date()
}

private struct RippleEffect: View {
    let ripple: CursorRipple
    let geo: GeometryProxy
    @State private var scale: CGFloat = 0.3
    @State private var opacity: Double = 0.8

    var body: some View {
        let pt = CGPoint(x: ripple.position.x * geo.size.width, y: ripple.position.y * geo.size.height)

        ZStack {
            // Outer ring
            Circle()
                .stroke(color.opacity(opacity * 0.5), lineWidth: 2)
                .frame(width: 50, height: 50)
                .scaleEffect(scale)

            // Inner ring
            Circle()
                .stroke(color.opacity(opacity), lineWidth: 1.5)
                .frame(width: 30, height: 30)
                .scaleEffect(scale * 0.8)

            // Flash fill
            Circle()
                .fill(color.opacity(opacity * 0.2))
                .frame(width: 50, height: 50)
                .scaleEffect(scale * 0.6)
        }
        .position(pt)
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) {
                scale = 2.0
                opacity = 0
            }
        }
    }

    private var color: Color {
        switch ripple.actionType {
        case "right_click": return .orange
        case "double_click", "triple_click": return .pink
        case "left_click_drag": return .purple
        default: return .cyan
        }
    }
}
