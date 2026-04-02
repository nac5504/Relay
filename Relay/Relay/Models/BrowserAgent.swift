import Foundation

@Observable
class BrowserAgent: Identifiable {
    let id: UUID
    var containerID: String?
    var status: AgentStatus = .starting
    var noVNCPort: Int
    var vncPort: Int
    var seleniumPort: Int
    var displayName: String
    var fps: Double = 0
    var errorMessage: String?

    var noVNCURL: URL {
        URL(string: "http://localhost:\(noVNCPort)/vnc.html?autoconnect=true&resize=scale&password=secret&view_only=false&reconnect=true&reconnect_delay=1000&host=localhost&port=\(noVNCPort)&path=websockify&encrypt=false")!
    }

    init(id: UUID = UUID(), noVNCPort: Int, vncPort: Int, seleniumPort: Int, displayName: String) {
        self.id = id
        self.noVNCPort = noVNCPort
        self.vncPort = vncPort
        self.seleniumPort = seleniumPort
        self.displayName = displayName
    }
}

enum AgentStatus: String {
    case starting
    case running
    case stopping
    case stopped
    case error
}
