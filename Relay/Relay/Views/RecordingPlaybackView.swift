import SwiftUI
import AVKit

/// Video player for completed agent recordings with chapter markers from plan steps.
struct RecordingPlaybackView: View {
    let agent: BrowserAgent
    @State private var player: AVPlayer?
    @State private var chapters: [Chapter] = []
    @State private var currentTime: Double = 0
    @State private var duration: Double = 1
    @State private var isPlaying = false
    @State private var timeObserver: Any?

    struct Chapter: Identifiable {
        let id: Int
        let title: String
        let timestampSeconds: Double
        let status: String
    }

    var body: some View {
        VStack(spacing: 0) {
            // Video player
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(16/9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ZStack {
                    Color(white: 0.04)
                    VStack(spacing: 12) {
                        Image(systemName: "film")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.2))
                        Text("Loading recording...")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
                .aspectRatio(16/9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Scrubber with chapter markers
            VStack(spacing: 6) {
                // Chapter markers on scrubber
                ZStack(alignment: .leading) {
                    // Track
                    GeometryReader { geo in
                        let width = geo.size.width

                        // Background track
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 4)
                            .frame(maxWidth: .infinity)

                        // Progress
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor)
                            .frame(width: max(0, width * (currentTime / max(duration, 1))), height: 4)

                        // Chapter markers
                        ForEach(chapters.filter { $0.status == "active" }) { ch in
                            let x = width * (ch.timestampSeconds / max(duration, 1))
                            Rectangle()
                                .fill(Color.cyan)
                                .frame(width: 2, height: 10)
                                .offset(x: x - 1, y: -3)
                        }

                        // Drag gesture for seeking
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        let frac = max(0, min(1, value.location.x / width))
                                        let target = frac * duration
                                        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
                                    }
                            )
                    }
                    .frame(height: 10)
                }

                // Chapter list
                if !chapters.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(chapters.filter { $0.status == "active" }) { ch in
                                Button {
                                    player?.seek(to: CMTime(seconds: ch.timestampSeconds, preferredTimescale: 600))
                                    player?.play()
                                    isPlaying = true
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(formatTime(ch.timestampSeconds))
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.cyan)
                                        Text(ch.title)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.6))
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.white.opacity(currentChapter(ch) ? 0.08 : 0.03))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(currentChapter(ch) ? Color.cyan.opacity(0.3) : Color.clear, lineWidth: 1)
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Playback controls
                HStack {
                    Button {
                        if isPlaying { player?.pause() } else { player?.play() }
                        isPlaying.toggle()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)

                    Text(formatTime(currentTime))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))

                    Text("/")
                        .foregroundStyle(.white.opacity(0.2))

                    Text(formatTime(duration))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))

                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onAppear { loadRecording() }
        .onDisappear { cleanup() }
    }

    private func loadRecording() {
        let remoteURL = APIService.shared.recordingURL(sessionId: agent.sessionId)
        print("[Playback] Loading recording from \(remoteURL)")

        // Download to temp file first — AVPlayer can't stream from localhost in sandboxed apps
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: remoteURL)
                let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(agent.sessionId).mp4")
                try data.write(to: tmpURL)
                print("[Playback] Downloaded \(data.count) bytes → \(tmpURL.path)")
                await MainActor.run {
                    let avPlayer = AVPlayer(url: tmpURL)
                    self.player = avPlayer
                    setupTimeObserver(avPlayer)
                }
            } catch {
                print("[Playback] Download failed: \(error)")
            }
        }

        // Load chapters from timeline
        Task {
            do {
                let timeline = try await APIService.shared.fetchTimeline(sessionId: agent.sessionId)
                if let steps = timeline["steps"] as? [[String: Any]] {
                    chapters = steps.compactMap { step in
                        guard let idx = step["stepIndex"] as? Int,
                              let title = step["title"] as? String,
                              let ts = step["timestampMs"] as? Double,
                              let status = step["status"] as? String else { return nil }
                        return Chapter(id: idx * 10 + (status == "active" ? 0 : 1),
                                       title: title, timestampSeconds: ts / 1000.0, status: status)
                    }
                }
            } catch {
                print("[Playback] Failed to load timeline: \(error)")
            }
        }
    }

    private func currentChapter(_ ch: Chapter) -> Bool {
        let nextChapter = chapters.filter { $0.status == "active" && $0.timestampSeconds > ch.timestampSeconds }.first
        let end = nextChapter?.timestampSeconds ?? duration
        return currentTime >= ch.timestampSeconds && currentTime < end
    }

    private func setupTimeObserver(_ avPlayer: AVPlayer) {
        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            currentTime = time.seconds
            if let dur = avPlayer.currentItem?.duration.seconds, dur.isFinite {
                duration = dur
            }
        }
    }

    private func cleanup() {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        player?.pause()
        player = nil
    }

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
