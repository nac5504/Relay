import SwiftUI

struct ContentView: View {
    @State private var store = MockAgentStore()
    @State private var selectedAgentId: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showChat = true

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                store: store,
                selectedAgentId: $selectedAgentId
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 360)
        } detail: {
            if let agentId = selectedAgentId,
               let agent = store.agents.first(where: { $0.id == agentId }) {
                AgentDetailView(agent: agent, store: store)
            } else {
                HomeGridView(store: store, selectedAgentId: $selectedAgentId)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $showChat) {
            MainChatView(store: store)
                .inspectorColumnWidth(min: 280, ideal: 360, max: 440)
        }
        
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation { showChat.toggle() }
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
                .help(showChat ? "Hide Chat" : "Show Chat")
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(minWidth: 900, minHeight: 600)
        .background(.thinMaterial)
        .preferredColorScheme(.dark)
    }
}
