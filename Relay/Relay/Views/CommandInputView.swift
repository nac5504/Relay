import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Data Types

struct AutocompleteSuggestion: Identifiable {
    let id: String
    let label: String
    let hint: String
    let color: Color
    let insertText: String
    var avatarURL: URL? = nil  // agent profile pic
}

// MARK: - Placeholder NSTextView

private class PlaceholderTextView: NSTextView {
    var placeholderString: String = "" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty,
              let container = textContainer, let lm = layoutManager else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.25),
            .font: font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        ]
        // Use the exact rect where the first glyph would be drawn
        let glyphRange = NSRange(location: 0, length: 0)
        let rect = lm.boundingRect(forGlyphRange: glyphRange, in: container)
        let origin = textContainerOrigin
        let point = NSPoint(x: rect.origin.x + origin.x, y: rect.origin.y + origin.y)
        NSAttributedString(string: placeholderString, attributes: attrs).draw(at: point)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

// MARK: - Highlighted Text Editor

struct HighlightedTextEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let tv = PlaceholderTextView()
        tv.placeholderString = placeholder
        tv.delegate = context.coordinator
        tv.font = font
        tv.textColor = .white
        tv.backgroundColor = .clear
        tv.insertionPointColor = .white
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = tv
        return scrollView
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? PlaceholderTextView else { return }
        context.coordinator.parent = self
        tv.placeholderString = placeholder
        if tv.string != text {
            context.coordinator.updating = true
            tv.string = text
            context.coordinator.highlight(tv)
            // Move cursor to end
            let end = (text as NSString).length
            tv.setSelectedRange(NSRange(location: end, length: 0))
            context.coordinator.updating = false
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HighlightedTextEditor
        var updating = false
        private let mentionRegex = try! NSRegularExpression(pattern: "@[a-zA-Z0-9_]+")
        private let commandRegex = try! NSRegularExpression(pattern: "(?:^|(?<=\\s))/[a-zA-Z0-9_]+")

        init(_ parent: HighlightedTextEditor) { self.parent = parent }

        func textDidChange(_ n: Notification) {
            guard !updating, let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            highlight(tv)
        }

        func textDidBeginEditing(_ n: Notification) { parent.onFocusChange(true) }
        func textDidEndEditing(_ n: Notification) { parent.onFocusChange(false) }

        func highlight(_ tv: NSTextView) {
            guard let s = tv.textStorage else { return }
            let t = tv.string
            let r = NSRange(location: 0, length: (t as NSString).length)
            guard r.length > 0 else { return }
            let sel = tv.selectedRanges
            s.beginEditing()
            s.addAttribute(.foregroundColor, value: NSColor.white, range: r)
            s.addAttribute(.font, value: parent.font, range: r)
            for m in mentionRegex.matches(in: t, range: r) {
                s.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: m.range)
            }
            for m in commandRegex.matches(in: t, range: r) {
                s.addAttribute(.foregroundColor, value: NSColor.systemCyan, range: m.range)
            }
            s.endEditing()
            tv.selectedRanges = sel
        }
    }
}

// MARK: - CommandInputView

struct CommandInputView: View {
    @Binding var text: String
    var placeholder: String = ""
    var suggestionsProvider: (String) -> [AutocompleteSuggestion] = { _ in [] }
    var onSend: (String) -> Void = { _ in }

    @State private var suggestions: [AutocompleteSuggestion] = []
    @State private var selectedIndex = 0
    @State private var showSuggestions = false
    @State private var keyMonitor: Any?
    @State private var attachedImages: [NSImage] = []
    @State private var isFocused = false

    var body: some View {
        VStack(spacing: 0) {
            // Autocomplete panel — floats above input
            if showSuggestions && !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { i, item in
                        Button { complete(item) } label: {
                            HStack(spacing: 10) {
                                if let url = item.avatarURL {
                                    CachedAvatarView(url: url, size: 20, fallbackColor: item.color)
                                }
                                Text(item.label)
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.9))
                                Spacer()
                                Text(item.hint)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.3))
                                if i == selectedIndex {
                                    HStack(spacing: 2) {
                                        keyBadge("tab")
                                        keyBadge("↵")
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(i == selectedIndex ? Color.white.opacity(0.08) : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if i < suggestions.count - 1 {
                            Divider().opacity(0.1)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.1))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1)))
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            // Input box
            VStack(spacing: 0) {
                // Attached images
                if !attachedImages.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(attachedImages.enumerated()), id: \.offset) { i, img in
                                ZStack(alignment: .topTrailing) {
                                    Image(nsImage: img)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1)))
                                    Button {
                                        attachedImages.remove(at: i)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white.opacity(0.8))
                                            .background(Circle().fill(Color.black.opacity(0.6)))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 4, y: -4)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                    }
                }

                HighlightedTextEditor(text: $text, placeholder: placeholder, onFocusChange: { isFocused = $0 })
                    .frame(minHeight: 36, maxHeight: 80)
                    .padding(.top, 8)
                    .onChange(of: text) { _, new in refreshSuggestions(new) }

                Divider().opacity(0.15)

                HStack(spacing: 12) {
                    Button { pickImages() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)

                    Button {
                        if text.isEmpty || text.hasSuffix(" ") {
                            text += "/"
                        } else {
                            text += " /"
                        }
                        isFocused = true
                    } label: {
                        Image(systemName: "slash.circle")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button(action: send) {
                        Image(systemName: "arrow.up.square.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(
                                text.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? .white.opacity(0.15) : .white
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12)))
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    // MARK: - Key Monitor

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard self.isFocused else { return event }

            switch event.keyCode {
            case 48: // Tab
                if self.showSuggestions, !self.suggestions.isEmpty {
                    self.complete(self.suggestions[self.selectedIndex])
                    return nil
                }
            case 36: // Return
                if event.modifierFlags.contains(.shift) { return event }
                if self.showSuggestions, !self.suggestions.isEmpty {
                    self.complete(self.suggestions[self.selectedIndex])
                    return nil
                }
                self.send()
                return nil
            case 126: // Up Arrow
                if self.showSuggestions, !self.suggestions.isEmpty {
                    self.selectedIndex = max(0, self.selectedIndex - 1)
                    return nil
                }
            case 125: // Down Arrow
                if self.showSuggestions, !self.suggestions.isEmpty {
                    self.selectedIndex = min(self.suggestions.count - 1, self.selectedIndex + 1)
                    return nil
                }
            default:
                break
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    // MARK: - Actions

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                if let img = NSImage(contentsOf: url) {
                    attachedImages.append(img)
                }
            }
        }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty || !attachedImages.isEmpty else { return }
        // Intercept /file command — open file picker instead of sending
        if t.lowercased() == "/file" {
            text = ""
            showSuggestions = false
            pickImages()
            return
        }
        text = ""
        attachedImages = []
        showSuggestions = false
        onSend(t)
    }

    private func complete(_ item: AutocompleteSuggestion) {
        // Intercept /file command — open file picker instead of inserting
        if item.insertText == "/file" {
            text = ""
            showSuggestions = false
            pickImages()
            return
        }
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if let last = words.last, last.hasPrefix("@") || last.hasPrefix("/") {
            words[words.count - 1] = item.insertText
        } else {
            words.append(item.insertText)
        }
        text = words.joined(separator: " ")
        if !text.hasSuffix(" ") { text += " " }
        showSuggestions = false
    }

    private func refreshSuggestions(_ text: String) {
        guard !text.isEmpty, !text.hasSuffix(" ") else {
            showSuggestions = false
            return
        }
        let word = text.split(separator: " ").last.map(String.init) ?? text
        guard word.hasPrefix("@") || word.hasPrefix("/") else {
            showSuggestions = false
            return
        }
        suggestions = suggestionsProvider(word)
        selectedIndex = 0
        showSuggestions = !suggestions.isEmpty
    }

    private func keyBadge(_ t: String) -> some View {
        Text(t)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.white.opacity(0.25))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08)))
    }
}

#Preview {
    @Previewable @State var text: String = ""

    let agents: [(name: String, status: String, color: Color)] = [
        ("George", "Working", .green),
        ("David", "Waiting for Input", .orange),
        ("Alice", "Starting", .yellow),
    ]

    let commands: [(name: String, desc: String)] = [
        ("file", "Attach a file"),
        ("summon", "Spawn a new agent"),
        ("stop", "Stop an agent"),
        ("status", "Check agent status"),
        ("logs", "View agent logs"),
    ]

    VStack {
        Spacer()
        CommandInputView(
            text: $text,
            placeholder: "@agent task, /summon name task...",
            suggestionsProvider: { trigger in
                if trigger.hasPrefix("@") {
                    let q = String(trigger.dropFirst()).lowercased()
                    return agents
                        .filter { q.isEmpty || $0.name.lowercased().hasPrefix(q) }
                        .map {
                            AutocompleteSuggestion(
                                id: "agent-\($0.name)",
                                label: "@\($0.name)", hint: $0.status,
                                color: $0.color, insertText: "@\($0.name)",
                                avatarURL: URL(string: "https://api.dicebear.com/9.x/bottts/png?seed=\($0.name)&size=64")
                            )
                        }
                } else if trigger.hasPrefix("/") {
                    let q = String(trigger.dropFirst()).lowercased()
                    return commands
                        .filter { q.isEmpty || $0.name.lowercased().hasPrefix(q) }
                        .map {
                            AutocompleteSuggestion(
                                id: "cmd-\($0.name)",
                                label: "/\($0.name)", hint: $0.desc,
                                color: .cyan, insertText: "/\($0.name)"
                            )
                        }
                }
                return []
            },
            onSend: { print("Send: \($0)") }
        )
    }
    .frame(width: 500, height: 400)
    .background(Color(white: 0.04))
}
