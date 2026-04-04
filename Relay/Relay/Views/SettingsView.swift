import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("anthropic_api_key") private var anthropicKey = ""
    @AppStorage("selected_chrome_profile") private var selectedChromeProfile = "Default"
    @AppStorage("apt_packages") private var aptPackagesStr = ""
    @AppStorage("pip_packages") private var pipPackagesStr = ""
    @State private var defaultModel = "claude-sonnet-4-6"
    @State private var maxTokens = 512

    @State private var keyDraft = ""
    @State private var connectionStatus: ConnectionStatus = .unknown
    @State private var isTesting = false

    // Chrome profile state
    @State private var chromeProfiles: [ChromeProfile] = []
    @State private var isLoadingProfiles = false

    // Docker image state
    @State private var imageStatus: ImageBuildStatus = .unknown
    @State private var isRebuildingImage = false
    @State private var buildProgress: Double = 0
    @State private var buildStep: String = ""
    @State private var aptDraft = ""
    @State private var pipDraft = ""

    struct ChromeProfile: Codable, Identifiable, Hashable {
        var id: String { dirName }
        let dirName: String
        let displayName: String
        let bookmarkCount: Int
    }

    enum ImageBuildStatus {
        case unknown, built, building, needsRebuild, error(String)

        var color: Color {
            switch self {
            case .unknown: return .gray
            case .built: return .green
            case .building: return .orange
            case .needsRebuild: return .yellow
            case .error: return .red
            }
        }

        var label: String {
            switch self {
            case .unknown: return "Unknown"
            case .built: return "Image ready"
            case .building: return "Building..."
            case .needsRebuild: return "Needs rebuild"
            case .error(let msg): return msg
            }
        }
    }

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

                    // Chrome Profile
                    settingsSection("Chrome Profile") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Sync profile to agents")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))

                            if isLoadingProfiles {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Detecting profiles...")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.4))
                                }
                            } else if chromeProfiles.isEmpty {
                                Text("No Chrome profiles found")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.3))
                            } else {
                                Picker("", selection: $selectedChromeProfile) {
                                    ForEach(chromeProfiles) { profile in
                                        Text("\(profile.displayName) (\(profile.bookmarkCount) bookmarks)")
                                            .tag(profile.dirName)
                                    }
                                }
                                .pickerStyle(.menu)
                                .onChange(of: selectedChromeProfile) { _, newValue in
                                    saveConfigToBackend()
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Bookmarks, history, and top sites sync on agent launch.")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.3))
                            Text("Log into sites once in-container; sessions persist across restarts.")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }

                    // Dependencies
                    settingsSection("Dependencies") {
                        settingsField("APT Packages", text: $aptDraft, hint: "nodejs, npm, htop, imagemagick")
                            .onChange(of: aptDraft) { _, newValue in
                                aptPackagesStr = newValue
                                imageStatus = .needsRebuild
                            }

                        settingsField("Pip Packages", text: $pipDraft, hint: "pandas, requests, openpyxl, matplotlib")
                            .onChange(of: pipDraft) { _, newValue in
                                pipPackagesStr = newValue
                                imageStatus = .needsRebuild
                            }

                        HStack(spacing: 10) {
                            Button {
                                rebuildImage()
                            } label: {
                                HStack(spacing: 6) {
                                    if isRebuildingImage {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "hammer.fill")
                                            .font(.caption)
                                    }
                                    Text(isRebuildingImage ? "Building..." : "Rebuild Image")
                                        .font(.system(.caption, design: .monospaced))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(imageStatus.color.opacity(0.2))
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isRebuildingImage)

                            if !isRebuildingImage {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(imageStatus.color)
                                        .frame(width: 8, height: 8)
                                    Text(imageStatus.label)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                            }

                            Spacer()
                        }

                        // Build progress bar
                        if isRebuildingImage {
                            VStack(alignment: .leading, spacing: 6) {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.white.opacity(0.08))
                                            .frame(height: 8)
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.accentColor)
                                            .frame(width: max(0, geo.size.width * buildProgress), height: 8)
                                            .animation(.easeInOut(duration: 0.3), value: buildProgress)
                                    }
                                }
                                .frame(height: 8)

                                Text(buildStep)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }

                        Text("Base image includes: Python 3.11, LibreOffice, Firefox, git, ffmpeg, Chromium")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.3))
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
        .frame(width: 480, height: 700)
        .background(Color(white: 0.08))
        .onAppear {
            keyDraft = anthropicKey
            aptDraft = aptPackagesStr
            pipDraft = pipPackagesStr
            Task {
                defaultModel = await ClaudeService.shared.model
                maxTokens = await ClaudeService.shared.maxTokens
            }
            if !anthropicKey.isEmpty {
                testConnection()
            }
            loadChromeProfiles()
            checkImageStatus()
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

    // MARK: - Backend API

    private let backendBase = URL(string: "http://localhost:3001")!

    private func loadChromeProfiles() {
        isLoadingProfiles = true
        Task {
            do {
                let url = backendBase.appendingPathComponent("config/chrome-profiles")
                let (data, _) = try await URLSession.shared.data(from: url)
                let profiles = try JSONDecoder().decode([ChromeProfile].self, from: data)
                await MainActor.run {
                    chromeProfiles = profiles
                    isLoadingProfiles = false
                }
            } catch {
                await MainActor.run {
                    chromeProfiles = []
                    isLoadingProfiles = false
                }
            }
        }
    }

    private func saveConfigToBackend() {
        Task {
            var request = URLRequest(url: backendBase.appendingPathComponent("config"))
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "content-type")

            let aptList = aptPackagesStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let pipList = pipPackagesStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

            let body: [String: Any] = [
                "chromeProfile": selectedChromeProfile,
                "aptPackages": aptList,
                "pipPackages": pipList,
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    private func rebuildImage() {
        isRebuildingImage = true
        imageStatus = .building
        buildProgress = 0
        buildStep = "Starting build..."
        saveConfigToBackend()

        Task {
            do {
                var request = URLRequest(url: backendBase.appendingPathComponent("config/rebuild-image"))
                request.httpMethod = "POST"
                request.timeoutInterval = 600
                let (_, _) = try await URLSession.shared.data(for: request)

                // Poll for progress
                while true {
                    try await Task.sleep(for: .seconds(1))
                    let statusURL = backendBase.appendingPathComponent("config/image-status")
                    let (data, _) = try await URLSession.shared.data(from: statusURL)
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let status = json["status"] as? String {

                        if status == "building" {
                            let progress = json["progress"] as? Double ?? 0
                            let step = json["step"] as? String ?? ""
                            await MainActor.run {
                                buildProgress = progress
                                buildStep = step
                            }
                        } else if status == "built" {
                            await MainActor.run {
                                buildProgress = 1.0
                                buildStep = "Complete"
                                imageStatus = .built
                                isRebuildingImage = false
                            }
                            break
                        } else {
                            let errMsg = json["error"] as? String ?? "Build failed"
                            await MainActor.run {
                                imageStatus = .error(String(errMsg.prefix(30)))
                                buildStep = "Failed"
                                isRebuildingImage = false
                            }
                            break
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    imageStatus = .error(String(error.localizedDescription.prefix(30)))
                    buildStep = "Failed"
                    isRebuildingImage = false
                }
            }
        }
    }

    private func checkImageStatus() {
        Task {
            do {
                let url = backendBase.appendingPathComponent("config/image-status")
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? String {
                    await MainActor.run {
                        switch status {
                        case "built": imageStatus = .built
                        case "building": imageStatus = .building
                        case "needs-rebuild": imageStatus = .needsRebuild
                        default: imageStatus = .unknown
                        }
                    }
                }
            } catch {
                // Backend not running — that's ok
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
