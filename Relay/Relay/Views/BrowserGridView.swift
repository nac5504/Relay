import SwiftUI

struct BrowserGridView: View {
    var agents: [BrowserAgent]
    var onCloseAgent: (BrowserAgent) -> Void

    private var columns: [GridItem] {
        let count = agents.count
        let cols = count <= 1 ? 1 : (count <= 4 ? 2 : 3)
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: cols)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(agents) { agent in
                BrowserTileView(agent: agent, onClose: { onCloseAgent(agent) })
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
            }
        }
        .padding(8)
    }
}
