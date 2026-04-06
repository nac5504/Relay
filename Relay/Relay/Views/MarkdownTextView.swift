import SwiftUI

// MARK: - Block-level Markdown Parser + Renderer

struct MarkdownTextView: View {
    let text: String
    var baseFontSize: Font.TextStyle = .callout
    var baseOpacity: Double = 0.85

    private var blocks: [MarkdownBlock] {
        parseBlocks(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            headingView(level: level, content: content)

        case .codeBlock(let code):
            codeBlockView(code)

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(item.number).")
                            .font(.system(baseFontSize, design: .monospaced, weight: .medium))
                            .foregroundStyle(.white.opacity(baseOpacity * 0.6))
                            .frame(width: 22, alignment: .trailing)
                        Text(inlineAttributed(item.text))
                            .font(.system(baseFontSize))
                            .foregroundStyle(.white.opacity(baseOpacity))
                            .lineSpacing(2)
                    }
                }
            }
            .padding(.leading, 4)

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(.white.opacity(baseOpacity * 0.4))
                            .frame(width: 4, height: 4)
                            .offset(y: -1)
                            .frame(width: 12)
                        Text(inlineAttributed(item))
                            .font(.system(baseFontSize))
                            .foregroundStyle(.white.opacity(baseOpacity))
                            .lineSpacing(2)
                    }
                }
            }
            .padding(.leading, 4)

        case .paragraph(let content):
            if !content.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(inlineAttributed(content))
                    .font(.system(baseFontSize))
                    .foregroundStyle(.white.opacity(baseOpacity))
                    .lineSpacing(3)
            }
        }
    }

    private func headingView(level: Int, content: String) -> some View {
        let fontSize: Font.TextStyle = level == 1 ? .title3 : level == 2 ? .headline : .subheadline
        let weight: Font.Weight = level <= 2 ? .bold : .semibold
        return Text(inlineAttributed(content))
            .font(.system(fontSize, design: .default, weight: weight))
            .foregroundStyle(.white.opacity(min(1.0, baseOpacity + 0.1)))
            .padding(.top, level == 1 ? 4 : 2)
    }

    private func codeBlockView(_ code: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }
}

// MARK: - Block Types

private enum MarkdownBlock {
    case heading(level: Int, content: String)
    case codeBlock(String)
    case orderedList([(number: Int, text: String)])
    case unorderedList([String])
    case paragraph(String)
}

// MARK: - Block Parser

private func parseBlocks(_ text: String) -> [MarkdownBlock] {
    let lines = text.components(separatedBy: "\n")
    var blocks: [MarkdownBlock] = []
    var i = 0

    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Fenced code block
        if trimmed.hasPrefix("```") {
            var codeLines: [String] = []
            i += 1
            while i < lines.count {
                let cl = lines[i]
                if cl.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    i += 1
                    break
                }
                codeLines.append(cl)
                i += 1
            }
            blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
            continue
        }

        // Heading
        if let match = trimmed.range(of: #"^(#{1,3})\s+(.+)$"#, options: .regularExpression) {
            let full = String(trimmed[match])
            let hashCount = full.prefix(while: { $0 == "#" }).count
            let content = String(full.drop(while: { $0 == "#" }).dropFirst()) // drop space
            blocks.append(.heading(level: hashCount, content: content))
            i += 1
            continue
        }

        // Ordered list: "1. ", "2. ", etc.
        if trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil {
            var items: [(number: Int, text: String)] = []
            while i < lines.count {
                let li = lines[i].trimmingCharacters(in: .whitespaces)
                if let match = li.range(of: #"^(\d+)\.\s+"#, options: .regularExpression) {
                    let numStr = String(li[li.startIndex..<li.firstIndex(of: ".")!])
                    let num = Int(numStr) ?? (items.count + 1)
                    items.append((number: num, text: String(li[match.upperBound...])))
                } else if li.isEmpty {
                    // Skip blank lines within a list — check if next non-blank line continues the list
                    var peek = i + 1
                    while peek < lines.count && lines[peek].trimmingCharacters(in: .whitespaces).isEmpty { peek += 1 }
                    if peek < lines.count && lines[peek].trimmingCharacters(in: .whitespaces).range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil {
                        i += 1
                        continue
                    }
                    break
                } else if li.range(of: #"^(#{1,3}\s|```|- |\* )"#, options: .regularExpression) != nil {
                    break
                } else {
                    // Continuation line
                    if !items.isEmpty {
                        items[items.count - 1].text += " " + li
                    }
                }
                i += 1
            }
            blocks.append(.orderedList(items))
            continue
        }

        // Unordered list: "- " or "* "
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            var items: [String] = []
            while i < lines.count {
                let li = lines[i].trimmingCharacters(in: .whitespaces)
                if li.hasPrefix("- ") || li.hasPrefix("* ") {
                    items.append(String(li.dropFirst(2)))
                } else if li.isEmpty || li.range(of: #"^(#{1,3}\s|```|\d+\.\s)"#, options: .regularExpression) != nil {
                    break
                } else {
                    if var last = items.last {
                        last += " " + li
                        items[items.count - 1] = last
                    }
                }
                i += 1
            }
            blocks.append(.unorderedList(items))
            continue
        }

        // Empty line — skip
        if trimmed.isEmpty {
            i += 1
            continue
        }

        // Paragraph: collect consecutive non-special lines
        var paraLines: [String] = []
        while i < lines.count {
            let pl = lines[i].trimmingCharacters(in: .whitespaces)
            if pl.isEmpty || pl.hasPrefix("#") || pl.hasPrefix("```")
                || pl.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil
                || pl.hasPrefix("- ") || pl.hasPrefix("* ") {
                break
            }
            paraLines.append(lines[i])
            i += 1
        }
        blocks.append(.paragraph(paraLines.joined(separator: " ")))
    }

    return blocks
}

// MARK: - Inline Attributed String (bold, italic, code, @mentions, /commands)

func inlineAttributed(_ text: String) -> AttributedString {
    let patterns: [(regex: String, style: (inout AttributedString) -> Void)] = [
        (#"\*\*(.+?)\*\*"#, { $0.font = .system(.callout, design: .default, weight: .semibold) }),
        (#"\*(.+?)\*"#,     { $0.font = .system(.callout, design: .default).italic() }),
        (#"`([^`]+)`"#,     { attr in
            attr.font = .system(.caption, design: .monospaced)
            attr.backgroundColor = .white.opacity(0.08)
        }),
        (#"@(\w+)"#,        { $0.foregroundColor = .blue }),
        (#"(/\w+)"#,        { $0.foregroundColor = .cyan }),
    ]

    struct Span {
        let range: Range<String.Index>
        let display: String
        let apply: (inout AttributedString) -> Void
    }

    var spans: [Span] = []
    for (pattern, style) in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        let nsRange = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: nsRange) {
            guard let fullRange = Range(match.range, in: text) else { continue }
            let displayRange = match.numberOfRanges > 1
                ? Range(match.range(at: 1), in: text) ?? fullRange
                : fullRange
            if spans.contains(where: { $0.range.overlaps(fullRange) }) { continue }
            spans.append(Span(range: fullRange, display: String(text[displayRange]), apply: style))
        }
    }
    spans.sort { $0.range.lowerBound < $1.range.lowerBound }

    var result = AttributedString()
    var cursor = text.startIndex
    for span in spans {
        if cursor < span.range.lowerBound {
            result.append(AttributedString(String(text[cursor..<span.range.lowerBound])))
        }
        var attr = AttributedString(span.display)
        span.apply(&attr)
        result.append(attr)
        cursor = span.range.upperBound
    }
    if cursor < text.endIndex {
        result.append(AttributedString(String(text[cursor...])))
    }
    return result
}
