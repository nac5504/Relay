import SwiftUI

struct VoiceWaveformButton: View {
    let isListening: Bool
    let audioLevel: CGFloat
    let action: () -> Void
    var compact: Bool = false

    private let barCount = 5

    @State private var barPhases: [Double] = [0, 0.6, 1.2, 0.4, 0.9]
    @State private var smoothedLevel: CGFloat = 0.0
    @State private var animationTimer: Timer?
    @State private var dotPulse = false

    private var circleSize: CGFloat { compact ? 20 : 24 }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isListening {
                    listeningContent
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                } else {
                    idleContent
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isListening)
        }
        .buttonStyle(.plain)
        .onChange(of: isListening) { _, listening in
            if listening {
                startAnimation()
            } else {
                stopAnimation()
            }
        }
        .onDisappear { stopAnimation() }
    }

    // MARK: - Idle State (circular waveform icon)

    private var idleContent: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.12))
                .frame(width: circleSize, height: circleSize)

            HStack(spacing: 1.5) {
                ForEach(0..<barCount, id: \.self) { i in
                    let heights: [CGFloat] = [0.35, 0.6, 1.0, 0.7, 0.4]
                    let maxH: CGFloat = compact ? 8 : 10
                    let h = max(2.5, maxH * heights[i])
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 1.5, height: h)
                }
            }
        }
        .frame(width: circleSize, height: circleSize)
    }

    // MARK: - Listening State (pill stop button)

    private var listeningContent: some View {
        HStack(spacing: 5) {
            HStack(spacing: 2.5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.red.opacity(0.9))
                        .frame(width: 4, height: 4)
                        .scaleEffect(dotPulse ? 1.0 : 0.5)
                        .animation(
                            .easeInOut(duration: 0.6)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.15),
                            value: dotPulse
                        )
                }
            }
            Text("Stop")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.red.opacity(0.9))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.red.opacity(0.1))
                .overlay(Capsule().stroke(Color.red.opacity(0.2), lineWidth: 0.5))
        )
    }

    // MARK: - Animation

    private func startAnimation() {
        smoothedLevel = 0.0
        dotPulse = true
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor in
                smoothedLevel = smoothedLevel * 0.65 + audioLevel * 0.35
                let rates: [Double] = [2.1, 2.7, 3.3, 2.5, 1.9]
                let dt = 1.0 / 30.0
                for i in 0..<barCount {
                    barPhases[i] += rates[i] * dt
                }
            }
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        smoothedLevel = 0.0
        dotPulse = false
    }
}
