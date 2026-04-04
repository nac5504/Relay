import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("anthropic_api_key") private var anthropicKey = ""
    @State private var defaultModel = "claude-sonnet-4-6"
    @State private var maxTokens = 512

    @State private var keyDraft = ""
    @State private var connectionStatus: ConnectionStatus = .unknown
    @State private var isTesting = false

    enum ConnectionStatus {
        case unknown, valid, invalid(String)

        var color: Color {
            switch self {
            case .unknown: return .gray
            case .valid: return .green
            case .invalid: return .red
            }
        }

        var label: String {
            switch self {
            case .unknown: return "Not tested"
            case .valid: return "Connected"
            case .invalid(let msg): return msg
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.system(.title3, design: .monospaced).bold())
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider().opacity(0.15)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // API Keys
                    settingsSection("API Keys") {
                        settingsField("Anthropic API Key", text: $keyDraft, isSecure: true, hint: "sk-ant-...")

                        HStack(spacing: 10) {
                            Button {
                                anthropicKey = keyDraft
                                testConnection()
                            } label: {
                                HStack(spacing: 6) {
                                    if isTesting {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption)
                                    }
                                    Text(isTesting ? "Testing..." : "Save & Test")
                                        .font(.system(.caption, design: .monospaced))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(keyDraft != anthropicKey
                                              ? Color.accentColor.opacity(0.3)
                                              : Color.white.opacity(0.06))
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(keyDraft.isEmpty || isTesting)

                            HStack(spacing: 5) {
                                Circle()
                                    .fill(connectionStatus.color)
                                    .frame(width: 8, height: 8)
                                Text(connectionStatus.label)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.5))
                            }

                            Spacer()
                        }
                    }

                    // Model
                    settingsSection("Model") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Default Model")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                            Picker("", selection: $defaultModel) {
                                Text("Haiku 4.5").tag("claude-haiku-4-5-20251001")
                                Text("Sonnet 4.6").tag("claude-sonnet-4-6")
                                Text("Opus 4.6").tag("claude-opus-4-6")
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: defaultModel) { _, newValue in
                                Task { await ClaudeService.shared.setModel(newValue) }
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Max Tokens")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                            HStack {
                                Slider(value: Binding(
                                    get: { Double(maxTokens) },
                                    set: { maxTokens = Int($0) }
                                ), in: 128...4096, step: 128)
                                Text("\(maxTokens)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .frame(width: 40)
                            }
                            .onChange(of: maxTokens) { _, newValue in
                                Task { await ClaudeService.shared.setMaxTokens(newValue) }
                            }
                        }
                    }

                    // About
                    settingsSection("About") {
                        HStack {
                            Text("Relay")
                                .font(.system(.callout, design: .monospaced))
                            Spacer()
                            Text("v0.1.0")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 480, height: 440)
        .background(Color(white: 0.08))
        .onAppear {
            keyDraft = anthropicKey
            Task {
                defaultModel = await ClaudeService.shared.model
                maxTokens = await ClaudeService.shared.maxTokens
            }
            if !anthropicKey.isEmpty {
                testConnection()
            }
        }
    }

    // MARK: - Connection Test

    private func testConnection() {
        let key = anthropicKey
        guard !key.isEmpty else {
            connectionStatus = .invalid("No key")
            return
        }
        isTesting = true
        connectionStatus = .unknown
        Task {
            do {
                var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                request.httpMethod = "POST"
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                request.setValue("application/json", forHTTPHeaderField: "content-type")
                request.timeoutInterval = 15

                let currentModel = await ClaudeService.shared.model
                let body: [String: Any] = [
                    "model": currentModel,
                    "max_tokens": 4,
                    "messages": [["role": "user", "content": "hi"]]
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let raw = String(data: data, encoding: .utf8) ?? ""

                await MainActor.run {
                    isTesting = false
                    if status == 200 {
                        connectionStatus = .valid
                    } else if raw.contains("invalid_api_key") || status == 401 {
                        connectionStatus = .invalid("Invalid key")
                    } else if raw.contains("permission") || status == 403 {
                        connectionStatus = .invalid("No permission")
                    } else {
                        connectionStatus = .invalid("HTTP \(status)")
                    }
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    connectionStatus = .invalid(String(error.localizedDescription.prefix(30)))
                }
            }
        }
    }

    // MARK: - Helpers

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(.caption2, design: .monospaced, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
                .tracking(1)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08)))
            )
        }
    }

    private func settingsField(_ label: String, text: Binding<String>, isSecure: Bool = false, hint: String = "") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))

            if isSecure {
                SecureField(hint, text: text)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.04))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1)))
                    )
            } else {
                TextField(hint, text: text)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.04))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1)))
                    )
            }
        }
    }
}

#Preview {
    SettingsView()
        .preferredColorScheme(.dark)
}
