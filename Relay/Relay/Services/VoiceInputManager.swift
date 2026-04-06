import SwiftUI
import Speech
import AVFoundation

@Observable @MainActor
final class VoiceInputManager {
    static let shared = VoiceInputManager()

    var isListening = false
    var isVoiceModeActive = false
    var error: String?
    var audioLevel: CGFloat = 0.0

    private var audioEngine = AVAudioEngine()
    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var permissionsGranted = false

    private var onTranscriptionUpdate: ((String) -> Void)?
    private var onAutoSend: (() -> Void)?

    /// Live agent names from the store, used for speech hints and @-mention conversion.
    private var agentNames: [String] {
        AgentStore.shared.agents.map(\.agentName)
    }

    private var silenceTimeout: Double {
        let stored = UserDefaults.standard.double(forKey: "voice_silence_timeout")
        return stored > 0 ? min(max(stored, 0.5), 3.0) : 2.0
    }

    private init() {}

    // MARK: - Permissions

    func requestPermissions() async -> Bool {
        guard !permissionsGranted else { return true }

        // Request speech recognition authorization
        let speechStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            error = "Speech recognition not authorized. Enable it in System Settings > Privacy & Security > Speech Recognition."
            return false
        }

        // Microphone access is handled implicitly when AVAudioEngine starts.
        // Non-sandboxed apps don't need AVCaptureDevice permission checks.
        permissionsGranted = true
        return true
    }

    // MARK: - Listening

    func startListening(onUpdate: @escaping (String) -> Void, onSend: @escaping () -> Void) {
        guard !isListening else { return }

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            error = "Speech recognition unavailable. Check that Siri & Dictation is enabled in System Settings."
            return
        }

        onTranscriptionUpdate = onUpdate
        onAutoSend = onSend
        error = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Hint agent names so the recognizer prioritizes them
        request.contextualStrings = agentNames + agentNames.map { "Hey \($0)" }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            request.append(buffer)

            // Compute RMS audio level for waveform visualization
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0.0
            for i in 0..<frameLength {
                let sample = channelData[i]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(frameLength))
            let level = min(CGFloat(rms * 5.0), 1.0)

            Task { @MainActor [weak self] in
                self?.audioLevel = level
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            self.error = "Audio engine failed: \(error.localizedDescription)"
            cleanup()
            return
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    let raw = result.bestTranscription.formattedString
                    let processed = self.processForSend(raw)
                    self.onTranscriptionUpdate?(processed)
                    self.resetSilenceTimer()

                    if result.isFinal {
                        self.finalize()
                    }
                }

                if let error {
                    self.error = error.localizedDescription
                    if self.isListening {
                        self.stopListening()
                    }
                }
            }
        }

        isListening = true
        isVoiceModeActive = true
    }

    func stopListening() {
        guard isListening else { return }
        cleanup()
        isListening = false
    }

    // MARK: - Agent Name Processing

    func processForSend(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return text }

        let lower = trimmed.lowercased()

        // "Hey AgentName ..." → "@AgentName ..."
        if lower.hasPrefix("hey ") {
            let afterHey = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            for name in agentNames {
                if afterHey.lowercased().hasPrefix(name.lowercased()) {
                    let rest = String(afterHey.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
                    let cleaned = rest.hasPrefix(",") ? String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) : rest
                    return cleaned.isEmpty ? "@\(name)" : "@\(name) \(cleaned)"
                }
            }
        }

        // Bare "AgentName ..." → "@AgentName ..."
        for name in agentNames {
            if lower.hasPrefix(name.lowercased()),
               (trimmed.count == name.count || trimmed[trimmed.index(trimmed.startIndex, offsetBy: name.count)] == " ") {
                let rest = String(trimmed.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
                return rest.isEmpty ? "@\(name)" : "@\(name) \(rest)"
            }
        }

        return trimmed
    }

    // MARK: - Private

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.finalize()
            }
        }
    }

    private func finalize() {
        stopListening()
        onAutoSend?()
        onAutoSend = nil
        onTranscriptionUpdate = nil
    }

    private func cleanup() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        audioLevel = 0.0
    }
}
