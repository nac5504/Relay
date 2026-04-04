import SwiftUI

struct BrowserGridView: View {
    var agents: [BrowserAgent]
    var mentionedAgentId: UUID? = nil
    var onCloseAgent: (BrowserAgent) -> Void
    var onSelectAgent: (BrowserAgent) -> Void
    @Binding var selectedAgentId: UUID?

    private let gap: CGFloat = 10
    private let tileAspect: CGFloat = 16.0 / 9.0

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let gridFrames = tileFrames(count: agents.count, in: size)
            let soloFrame = tileFrames(count: 1, in: size).first ?? .zero
            let hasSelection = selectedAgentId != nil

            ZStack {
                ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                    if index < gridFrames.count {
                        let isSelected = selectedAgentId == agent.id
                        let frame = isSelected ? soloFrame : gridFrames[index]

                        BrowserTileView(
                            agent: agent,
                            isMentioned: mentionedAgentId == agent.id,
                            onClose: { onCloseAgent(agent) }
                        )
                        .overlay(alignment: .topLeading) {
                            HStack(spacing: 8) {
                                CachedAvatarView(url: agent.avatarURL, size: 24)
                                Text(agent.agentName)
                                    .font(.system(size: 18, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(.black.opacity(0.7))
                            }
                            .padding(8)
                            .opacity(isSelected ? 0 : 1)
                            .animation(.easeOut(duration: 0.15), value: selectedAgentId)
                        }
                        .frame(width: frame.width, height: frame.height)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard selectedAgentId == nil else { return }
                            onSelectAgent(agent)
                        }
                        .position(x: frame.midX, y: frame.midY)
                        .animation(.spring(response: 0.55, dampingFraction: 0.82).delay(0.12), value: selectedAgentId)
                        .scaleEffect(hasSelection && !isSelected ? 0.7 : 1)
                        .opacity(hasSelection && !isSelected ? 0 : 1)
                        .animation(.easeOut(duration: 0.2), value: selectedAgentId)
                        .zIndex(isSelected ? 10 : 0)
                    }
                }
            }
        }
        .clipped()
    }

    // MARK: - Layout computation

    private func tileFrames(count: Int, in size: CGSize) -> [CGRect] {
        guard count > 0 else { return [] }

        switch count {
        case 1:
            return layoutRows([[0]], tileCount: 1, in: size)

        case 2:
            return layoutRows([[0], [1]], tileCount: 2, in: size)

        case 3:
            return layoutRows([[0], [1, 2]], tileCount: 3, in: size)

        default:
            let cols = count <= 4 ? 2 : 3
            var rows: [[Int]] = []
            var idx = 0
            while idx < count {
                let remaining = count - idx
                let remainingRows = Int(ceil(Double(remaining) / Double(cols)))
                let inThisRow = remainingRows == 1 ? remaining : cols
                rows.append(Array(idx..<idx + inThisRow))
                idx += inThisRow
            }
            return layoutRows(rows, tileCount: count, in: size)
        }
    }

    private func layoutRows(_ rows: [[Int]], tileCount: Int, in size: CGSize) -> [CGRect] {
        let numRows = rows.count
        let maxCols = rows.map(\.count).max() ?? 1

        let availW = size.width - gap * CGFloat(maxCols + 1)
        let availH = size.height - gap * CGFloat(numRows + 1)

        let tileW: CGFloat
        let tileH: CGFloat
        let candidateW = availW / CGFloat(maxCols)
        let candidateH = availH / CGFloat(numRows)

        if candidateW / tileAspect <= candidateH {
            tileW = candidateW
            tileH = tileW / tileAspect
        } else {
            tileH = candidateH
            tileW = tileH * tileAspect
        }

        let totalH = CGFloat(numRows) * tileH + CGFloat(numRows - 1) * gap
        let startY = (size.height - totalH) / 2

        var frames = Array(repeating: CGRect.zero, count: tileCount)

        for (rowIdx, row) in rows.enumerated() {
            let rowW = CGFloat(row.count) * tileW + CGFloat(row.count - 1) * gap
            let startX = (size.width - rowW) / 2

            for (colIdx, tileIdx) in row.enumerated() {
                frames[tileIdx] = CGRect(
                    x: startX + CGFloat(colIdx) * (tileW + gap),
                    y: startY + CGFloat(rowIdx) * (tileH + gap),
                    width: tileW,
                    height: tileH
                )
            }
        }

        return frames
    }
}
